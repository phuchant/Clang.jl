function wrap_type!(ctx::AbstractContext, type::CLType)
    decl_cursor::Union{CLCursor,Nothing} = nothing

    if typeof(type) <: Union{CLVector,CLConstantArray,CLIncompleteArray,CLVariableArray,CLDependentSizedArray,CLComplex}
        decl_cursor = clang_getCursorDefinition(typedecl(element_type(type)))
    else
        decl_cursor = clang_getCursorDefinition(typedecl((type)))
    end

    if !(decl_cursor in ctx.visited)
        push!(ctx.visited, decl_cursor)
        enqueue!(ctx.queue, decl_cursor)
    end
end

"""
    wrap!(ctx::AbstractContext, cursor::CLFunctionDecl)
Subroutine for handling function declarations. Note that VarArg functions are not supported.
"""
function wrap!(ctx::AbstractContext, cursor::CLFunctionDecl)
    func_type = type(cursor)
    if kind(func_type) == CXType_FunctionNoProto
        @warn "No Prototype for $cursor - assuming no arguments"
    end

    func_name = isempty(ctx.force_name) ? Symbol(spelling(cursor)) : ctx.force_name
    ret_type = clang2julia(return_type(cursor))
    args = function_args(cursor)
    arg_types = [argtype(func_type, i) for i in 0:length(args)-1]
    arg_reps = clang2julia.(arg_types)
    for (i, arg) in enumerate(arg_reps)
        # constant array argument should be converted to Ptr
        # e.g. double f[3] => Ptr{Cdouble} instead of NTuple{3, Cdouble}
        if Meta.isexpr(arg, :curly) && first(arg.args) == :NTuple
            arg_reps[i] = Expr(:curly, :Ptr, last(arg.args))
        end
    end

    # Wrap return type and argument types
    for arg_type in arg_types
        wrap_type!(ctx, arg_type)
    end
    wrap_type!(ctx, return_type(cursor))

    # handle unnamed args and convert names to symbols
    arg_count = 0
    arg_names = map(args) do x
                    n = name_safe(name(x))
                    s = !isempty(n) ? n : "arg"*string(arg_count+=1)
                    Symbol(s)
    end

    signature = efunsig(func_name, arg_names, arg_reps)
    if isvariadic(func_type)
        push!(signature.args, Expr(:(...), :var_arg))
    end

    ctx.libname == "libxxx" && @warn "default libname: libxxx are being used, did you forget to specify `context.libname`?"


    block = Expr(:block)
    push!(ctx.api_buffer, Expr(:macrocall, Symbol("@cbindings"), nothing, symbol_safe(ctx.libname), block))
    push!(block.args, Expr(:macrocall, Symbol("@cextern"), nothing, Expr(:(::), signature, ret_type)))

    return ctx
end

function is_ptr_type_expr(@nospecialize t)
    (t === :Cstring || t === :Cwstring) && return true
    isa(t, Expr) || return false
    t = t::Expr
    t.head === :curly && t.args[1] === :Ptr
end

function efunsig(name::Symbol, args::Vector{Symbol}, types)
    x = [Expr(:(::), a, t) for (a,t) in zip(args,types)]
    Expr(:call, name, x...)
end

function eccall(func_name::Symbol, libname::Symbol, rtype, args, types)
  :(ccall(($(QuoteNode(func_name)), $libname),
            $rtype,
            $(Expr(:tuple, types...)),
            $(args...))
    )
end

"""
    wrap!(ctx::AbstractContext, cursor::CLEnumDecl)
Subroutine for handling enum declarations.
"""
function wrap!(ctx::AbstractContext, cursor::CLEnumDecl)
    cursor_name = name(cursor)
    # handle typedef anonymous enum
    next_cursor = get(ctx.next_cursor, cursor, nothing)
    if next_cursor != nothing && is_typedef_anon(cursor, next_cursor)
        cursor_name = name(next_cursor)
    end

    !isempty(ctx.force_name) && (cursor_name = ctx.force_name;)
    cursor_name == "" && (@warn("Skipping unnamed EnumDecl: $cursor"); return ctx)

    enum_sym = symbol_safe(cursor_name)
    enum_type = INT_CONVERSION[clang2julia(cursor)]
    name2value = Tuple{Symbol,Int}[]
    # extract values and names
    for item_cursor in children(cursor)
        kind(item_cursor) == CXCursor_PackedAttr && (@warn("this is a `__attribute__((packed))` enum, the underlying alignment of generated structure may not be compatible with the original one in C!"); continue)
        item_name = spelling(item_cursor)
        isempty(item_name) && continue
        item_sym = symbol_safe(item_name)
        push!(name2value, (item_sym, value(item_cursor)))
    end

    expr = Expr(:macrocall, Symbol("@cenum"), nothing, Expr(:(::), enum_sym, enum_type))
    enum_pairs = Expr(:block)
    ctx.common_buffer[enum_sym] = ExprUnit(expr)
    for (name,value) in name2value
        ctx.common_buffer[name] = ctx.common_buffer[enum_sym]  ##???
        push!(enum_pairs.args, :($name = $value))
    end
    push!(expr.args, enum_pairs)

    return ctx
end

"""
    wrap!(ctx::AbstractContext, cursor::CLStructDecl)
Subroutine for handling struct declarations.
"""
function wrap!(ctx::AbstractContext, cursor::CLStructDecl)
    # make sure a empty struct is indeed an opaque struct typedef/typealias
    cursor = type(cursor) |> canonical |> typedecl
    cursor_name = name(cursor)
    # handle typedef anonymous struct
    next_cursor = get(ctx.next_cursor,cursor,nothing)
    if next_cursor != nothing && is_typedef_anon(cursor, next_cursor)
        cursor_name = name(next_cursor)
    end
    !isempty(ctx.force_name) && (cursor_name = ctx.force_name;)
    cursor_name == "" && (@warn("Skipping unnamed StructDecl: $cursor"); return ctx)

    struct_sym = symbol_safe(cursor_name)
    buffer = ctx.common_buffer

    # generate struct declaration
    block = Expr(:bracescat)
    expr = Expr(:macrocall, Symbol("@cstruct"), nothing, struct_sym, block)
    deps = OrderedSet{Symbol}()
    struct_fields = children(cursor)
    for (field_idx, field_cursor) in enumerate(struct_fields)
        field_name = name(field_cursor)
        field_kind = kind(field_cursor)

        alignment = get(ctx.fields_align, (struct_sym, symbol_safe(field_name)), nothing)
        if alignment != nothing
            push!(block.args, Expr(:macrocall, Symbol("@calign"), nothing, alignment))
        end

        if field_kind == CXCursor_StructDecl || field_kind == CXCursor_UnionDecl || field_kind == CXCursor_EnumDecl
            continue
        elseif field_kind == CXCursor_FirstAttr
            continue
        elseif field_kind != CXCursor_FieldDecl || field_kind == CXCursor_TypeRef
            buffer[struct_sym] = ExprUnit(Poisoned())
            @warn "Skipping struct: \"$cursor\" due to unsupported field: $field_cursor"
            return ctx
        elseif isempty(field_name)
            error("Unnamed struct member in: $cursor ... cursor: $field_cursor")
        end

        # anonymous field
        if occursin("anonymous", string(clang2julia(field_cursor)))
            children_cursors = children(field_cursor)

            # union field
            if kind(children_cursors[1]) == CXCursor_UnionDecl
                union_block = Expr(:bracescat)
                union_expr = Expr(:macrocall, Symbol("@cunion"), nothing, union_block)

                for union_field in children(children_cursors[1])
                    repr = clang2julia(union_field)
                    union_field_name = name(union_field)
                    push!(union_block.args, Expr(:(::), symbol_safe(union_field_name), repr))
                    push!(deps, target_type(repr))
                    wrap_type!(ctx, type(union_field))
                end
                push!(block.args, union_expr)
                continue
            end

            idx = field_idx-1
            anonymous_record = struct_fields[idx]
            while idx != 0 && kind(anonymous_record) == CXCursor_FieldDecl
                idx -= 1
                anonymous_record = struct_fields[idx]
            end
            if idx == field_idx-1
                ctx.anonymous_counter += 1
                anon_name = "ANONYMOUS$(ctx.anonymous_counter)_"*spelling(field_cursor)
                ctx.force_name = anon_name
                wrap!(ctx, anonymous_record)
                ctx.force_name = ""
                repr = symbol_safe(anon_name)
            else
                anon_name = "ANONYMOUS$(ctx.anonymous_counter)_"*spelling(struct_fields[idx+1])
                repr = symbol_safe(anon_name)
            end

            push!(block.args, Expr(:(::), symbol_safe(field_name), repr))
            push!(deps, target_type(repr))
            continue
        end

        # bitfield
        if clang_Cursor_isBitField(field_cursor) == 1
            repr = clang2julia(field_cursor)
            bit_width = clang_getFieldDeclBitWidth(field_cursor)
            symbol = symbol_safe(field_name)
            push!(block.args, Expr(:(::), :($symbol:$bit_width), repr))
            push!(deps, target_type(repr))
            continue
        end

        repr = clang2julia(field_cursor)
        wrap_type!(ctx, type(field_cursor))
        push!(block.args, Expr(:(::), symbol_safe(field_name), repr))
        push!(deps, target_type(repr))
    end

    # check for a previous forward ordering
    if !(struct_sym in keys(buffer)) || buffer[struct_sym].state == :empty
        if !isempty(struct_fields)
            buffer[struct_sym] = ExprUnit(expr, deps)
        else
            # opaque struct typedef/typealias
            buffer[struct_sym] = ExprUnit(:(const $struct_sym = Cvoid), deps, state=:empty)
        end
    end

    return ctx
end

"""
    wrap!(ctx::AbstractContext, cursor::CLUnionDecl)
Subroutine for handling union declarations.
"""
function wrap!(ctx::AbstractContext, cursor::CLUnionDecl)
    # make sure a empty union is indeed an opaque union typedef/typealias
    # cursor = canonical(cursor)  # this won't work
    cursor = type(cursor) |> canonical |> typedecl
    cursor_name = name(cursor)
    # handle typedef anonymous union
    next_cursor = ctx.next_cursor[cursor]
    if next_cursor != nothing && is_typedef_anon(cursor, next_cursor)
        cursor_name = name(next_cursor)
    end
    !isempty(ctx.force_name) && (cursor_name = ctx.force_name;)
    cursor_name == "" && (@warn("Skipping unnamed UnionDecl: $cursor"); return ctx)

    union_sym = symbol_safe(cursor_name)
    buffer = ctx.common_buffer

    # generate union declaration
    block = Expr(:bracescat)
    expr = Expr(:macrocall, Symbol("@cunion"), nothing, union_sym, block)
    deps = OrderedSet{Symbol}()
    union_fields = children(cursor)
    for (field_idx, field_cursor) in enumerate(union_fields)
        field_name = name(field_cursor)
        field_kind = kind(field_cursor)

        if field_kind == CXCursor_StructDecl || field_kind == CXCursor_UnionDecl || field_kind == CXCursor_EnumDecl
            continue
        elseif field_kind == CXCursor_FirstAttr
            continue
        elseif field_kind != CXCursor_FieldDecl || field_kind == CXCursor_TypeRef
            buffer[union_sym] = ExprUnit(Poisoned())
            @warn "Skipping union: \"$cursor\" due to unsupported field: $field_cursor"
            return ctx
        elseif isempty(field_name)
            error("Unnamed union member in: $cursor ... cursor: $field_cursor")
        end

        repr = clang2julia(field_cursor)
        push!(block.args, Expr(:(::), symbol_safe(field_name), repr))
        push!(deps, target_type(repr))
        wrap_type!(ctx, type(field_cursor))
    end

    # check for a previous forward ordering
    if !(union_sym in keys(buffer)) || buffer[union_sym].state == :empty
        if !isempty(union_fields)
            buffer[union_sym] = ExprUnit(expr, deps)
        else
            # opaque union typedef/typealias
            buffer[union_sym] = ExprUnit(:(const $union_sym = Cvoid), deps, state=:empty)
        end
    end

    return ctx
end

"""
    wrap!(ctx::AbstractContext, cursor::CLTypedefDecl)
Subroutine for handling typedef declarations.
"""
function wrap!(ctx::AbstractContext, cursor::CLTypedefDecl)
    td_type = underlying_type(cursor)
    td_sym = isempty(ctx.force_name) ? Symbol(spelling(cursor)) : ctx.force_name
    buffer = ctx.common_buffer
    if kind(td_type) == CXType_Unexposed
        # TODO: which corner case will trigger this pass?
        @error "Skipping Typedef: CXType_Unexposed, $cursor, please report this on Github."
    end

    if kind(td_type) == CXType_FunctionProto
        # TODO: need to find a test case too
        if !haskey(buffer, td_sym)
            buffer[td_sym] = ExprUnit(string("# Skipping Typedef: CXType_FunctionProto ", spelling(cursor)))
        end
        return ctx
    end

    td_target = clang2julia(td_type)

    if td_target == td_sym
        return wrap!(ctx, typedecl(typedef_type(cursor)))
    end

    if !haskey(buffer, td_sym)
        buffer[td_sym] = ExprUnit(:(const $td_sym = $td_target), [td_target])
        wrap_type!(ctx, typedef_type(cursor))
    end
    return ctx
end

"""
    wrap!(ctx::AbstractContext, cursor::CLMacroDefinition)
Subroutine for handling macro declarations.
"""
function wrap!(ctx::AbstractContext, cursor::CLMacroDefinition)

    # normalize literal with a size suffix
    function literally(tok)
        # note: put multi-character first, or it will break out too soon for those!
        literalsuffixes = ["ULL", "Ull", "uLL", "ull", "LLU", "LLu", "llU", "llu",
                           "LL", "ll", "UL", "Ul", "uL", "ul", "LU", "Lu", "lU", "lu",
                           "U", "u", "L", "l", "F", "f"]

        function literal_totype(literal, txt)
            literal = lowercase(literal)

            # Floats following http://en.cppreference.com/w/cpp/language/floating_literal
            float64 = occursin(".", txt) && occursin("l", literal)
            float32 = occursin("f", literal)

            if float64 || float32
                float64 && return "Float64"
                float32 && return "Float32"
            end

            # Integers following http://en.cppreference.com/w/cpp/language/integer_literal
            unsigned = occursin("u", literal)
            nbits = count(x -> x == 'l', literal) == 2 ? 64 : 32
            return "$(unsigned ? "U" : "")Int$nbits"
        end

        txt = tok.text |> strip
        for sfx in literalsuffixes
            if endswith(txt, sfx)
                type = literal_totype(sfx, txt)
                txt = txt[1:end-length(sfx)]
                txt = "$(type)($txt)"
                break
            end
        end
        return txt
    end

    tokens = tokenize(cursor)

    # Skip any empty definitions
    tokens.size < 2 && return ctx
    startswith(name(cursor), "_") && return ctx

    buffer = ctx.common_buffer

    exprn = ""
    deps = []
    prev_kind = nothing
    for i in 2:tokens.size
        token = tokens[i]
        token_kind = kind(token)
        token_text = token.text
        if token_kind == CXToken_Literal
            if prev_kind == CXToken_Literal
                @warn "Skipping CLMacroDefinition: $cursor"
                return ctx
            end
            exprn *= literally(token)
        elseif token_kind == CXToken_Identifier
            exprn *= token.text
            push!(deps, symbol_safe(token_text))
        elseif token_kind == CXToken_Punctuation

            # Do not translate macro containing function calls
            if token_text == "(" && prev_kind == CXToken_Identifier
                @warn "Skipping CLMacroDefinition: $cursor"
                return ctx
            end

            if token_text ∈ ["+" "-" "*" "~" ">>" "<<" "/" "\\" "%" "|" "||" "^" "&" "&&" "(" ")"]
                exprn *= token.text
            else
                @warn "Skipping CLMacroDefinition: $cursor"
                return ctx
            end
        else
            @warn "Skipping CLMacroDefinition: $cursor"
            return ctx
        end
        prev_kind = token_kind
    end

    use_sym = symbol_safe(tokens[1].text)

    try
        target = Meta.parse(exprn)
        if use_sym == target
            return ctx
        end

        e = Expr(:const, Expr(:(=), use_sym, target))
        buffer[use_sym] = ExprUnit(e, deps)
    catch err
        @warn "Skipping CLMacroDefinition: $cursor"
    end

    return ctx
end

"""
    wrap!(ctx::AbstractContext, cursor::CLTypeRef)
For now, we just skip CXCursor_TypeRef cursors.
"""
function wrap!(ctx::AbstractContext, cursor::CLTypeRef)
    @warn "Skipping CXCursor_TypeRef cursor: $cursor"
    return ctx
end

function wrap!(ctx::AbstractContext, cursor::CLCursor)
    @warn "not wrapping $(cursor)"
    return ctx
end

function wrap!(ctx::AbstractContext, cursor::CLMacroInstantiation)
    # tokens = tokenize(cursor)
    # for token in tokens
    #     print(token.text, " ")
    # end
    println(cursor, children(cursor))
    @warn "not wrapping $(cursor)"
    return ctx
end


function wrap!(ctx::AbstractContext, cursor::CLLastPreprocessing)
    @debug "not wrapping $(cursor)"
    return ctx
end
