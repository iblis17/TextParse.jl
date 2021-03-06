import Base.show

export CustomParser, Quoted

using Compat

@compat abstract type AbstractToken{T} end
fieldtype{T}(::AbstractToken{T}) = T
fieldtype{T}(::Type{AbstractToken{T}}) = T
fieldtype{T<:AbstractToken}(::Type{T}) = fieldtype(supertype(T))

"""
`tryparsenext{T}(tok::AbstractToken{T}, str, i, till, localopts)`

Parses the string `str` starting at position `i` and ending at or before position `till`. `localopts` is a [LocalOpts](@ref) object which contains contextual options for quoting and NA parsing. (see [LocalOpts](@ref) documentation)

`tryparsenext` returns a tuple `(result, nextpos)` where `result` is of type `Nullable{T}`, null if parsing failed, non-null containing the parsed value if it succeeded. If parsing succeeded, `nextpos` is the position the next token, if any, starts at. If parsing failed, `nextpos` is the position at which the parsing failed.
"""
function tryparsenext end

## options passed down for tokens (specifically NAToken, StringToken)
## inside a Quoted token
"""
    LocalOpts

Options local to the token currently being parsed.
- `endchar`: Till where to parse. (e.g. delimiter or quote ending character)
- `spacedelim`: Treat spaces as delimiters
- `quotechar`: the quote character
- `escapechar`: char that escapes the quote
- `includequotes`: whether to include quotes while parsing
- `includenewlines`: whether to include newlines while parsing
"""
immutable LocalOpts
    endchar::Char         # End parsing at this char
    spacedelim::Bool
    quotechar::Char       # Quote char
    escapechar::Char      # Escape char
    includequotes::Bool   # Whether to include quotes in string parsing
    includenewlines::Bool # Whether to include newlines in string parsing
end

const default_opts = LocalOpts(',', false, '"', '"', false, false)
# helper function for easy testing:
@inline function tryparsenext(tok::AbstractToken, str, opts::LocalOpts=default_opts)
    tryparsenext(tok, str, start(str), endof(str), opts)
end

# fallback for tryparsenext methods which don't care about local opts
@inline function tryparsenext(tok::AbstractToken, str, i, len, locopts)
    tryparsenext(tok, str, i, len)
end

immutable WrapLocalOpts{T, X<:AbstractToken} <: AbstractToken{T}
    opts::LocalOpts
    inner::X
end

WrapLocalOpts(opts, inner) = WrapLocalOpts{fieldtype(inner), typeof(inner)}(opts, inner)

@inline function tryparsenext(tok::WrapLocalOpts, str, i, len, opts::LocalOpts=default_opts)
    tryparsenext(tok.inner, str, i, len, tok.opts)
end


# needed for promoting guessses
immutable Unknown <: AbstractToken{Union{}} end
fromtype(::Type{Union{}}) = Unknown()
const nullableNA = Nullable{DataValue{Union{}}}(DataValue{Union{}}())
function tryparsenext(::Unknown, str, i, len, opts)
    nullableNA, i
end
show(io::IO, ::Unknown) = print(io, "<unknown>")
immutable CustomParser{T, F} <: AbstractToken{T}
    f::Function
end

"""
    CustomParser(f, T)

Provide a custom parsing mechanism.

# Arguments:

- `f`: the parser function
- `T`: The type of the parsed value

The parser function must take the following arguments:
- `str`: the entire string being parsed
- `pos`: the position in the string at which to start parsing
- `len`: the length of the string the maximum position where to parse till
- `opts`: a [LocalOpts](@ref) object with options local to the current field.

The parser function must return a tuple of two values:

- `result`: A `Nullable{T}`. Set to null if parsing must fail, containing the value otherwise.
- `nextpos`: If parsing succeeded this must be the next position after parsing finished, if it failed this must be the position at which parsing failed.
"""
CustomParser(f, T) = CustomParser{T,typeof(f)}(f)

show{T}(io::IO, c::CustomParser{T}) = print(io, "{{custom:$T}}")

@inline function tryparsenext(c::CustomParser, str, i, len, opts)
    c.f(str, i, len, opts)
end


# Numberic parsing
"""
parse numbers of type T
"""
immutable Numeric{T} <: AbstractToken{T}
    decimal::Char
    thousands::Char
end
show{T}(io::IO, c::Numeric{T}) = print(io, "<$T>")

Numeric{T}(::Type{T}, decimal='.', thousands=',') = Numeric{T}(decimal, thousands)
fromtype{N<:Number}(::Type{N}) = Numeric(N)

### Unsigned integers

function tryparsenext{T<:Signed}(::Numeric{T}, str, i, len)
    R = Nullable{T}
    @chk2 sign, i = tryparsenext_sign(str, i, len)
    @chk2 x, i = tryparsenext_base10(T, str, i, len)

    @label done
    return R(sign*x), i

    @label error
    return R(), i
end

@inline function tryparsenext{T<:Unsigned}(::Numeric{T}, str, i, len)
    tryparsenext_base10(T,str, i, len)
end

@inline function tryparsenext{F<:AbstractFloat}(::Numeric{F}, str, i, len)
    R = Nullable{F}
    f = 0.0
    @chk2 sign, i = tryparsenext_sign(str, i, len)
    x=0

    i > len && @goto error
    c, ii = next(str, i)
    if c == '.'
        i=ii
        @goto dec
    end
    @chk2 x, i = tryparsenext_base10(Int, str, i, len)
    i > len && @goto done
    @inbounds c, ii = next(str, i)

    c != '.' && @goto parse_e
    @label dec
    @chk2 y, i = tryparsenext_base10(Int, str, ii, len) done
    f = y / 10.0^(i-ii)

    i > len && @goto done
    c, ii = next(str, i)

    @label parse_e
    if c == 'e' || c == 'E'
        @chk2 exp, i = tryparsenext(Numeric(Int), str, ii, len)
        return R(sign*(x+f) * 10.0^exp), i
    end

    @label done
    return R(sign*(x+f)), i

    @label error
    return R(), i
end

immutable Percentage <: AbstractToken{Float64}
end

const floatparser = Numeric(Float64)
function tryparsenext(::Percentage, str, i, len, opts)
    num, ii = tryparsenext(floatparser, str, i, len, opts)
    if isnull(num)
        return num, ii
    else
        # parse away the % char
        ii = eatwhitespaces(str, ii, len)
        c, k = next(str, ii)
        if c != '%'
            return Nullable{Float64}(), ii # failed to parse %
        else
            return Nullable{Float64}(num.value / 100.0), k # the point after %
        end
    end
end

"""
Parses string to the AbstractString type `T`. If `T` is `StrRange` returns a
`StrRange` with start position (`offset`) and `length` of the substring.
It is used internally by `csvparse` for avoiding allocating strings.
"""
immutable StringToken{T} <: AbstractToken{T}
end

function StringToken{T}(t::Type{T})
    StringToken{T}()
end
show(io::IO, c::StringToken) = print(io, "<string>")

fromtype{S<:AbstractString}(::Type{S}) = StringToken(S)

function tryparsenext{T}(s::StringToken{T}, str, i, len, opts)
    R = Nullable{T}
    p = ' '
    i0 = i
    if opts.includequotes && i <= len
        c, ii = next(str, i)
        if c == opts.quotechar
            i = ii # advance counter so that
                   # the while loop doesn't react to opening quote
        end
    end

    while i <= len
        c, ii = next(str, i)
        if opts.spacedelim && (c == ' ' || c == '\t')
            break
        elseif !opts.spacedelim && c == opts.endchar
            if opts.endchar == opts.quotechar
                # this means we're inside a quoted string
                if opts.quotechar == opts.escapechar
                    # sometimes the quotechar is the escapechar
                    # in that case we need to see the next char
                    if ii > len
                        if opts.includequotes
                            i=ii
                        end
                        break
                    end
                    nxt, j = next(str, ii)
                    if nxt == opts.quotechar
                        # the current character is escaping the
                        # next one
                        i = j # skip next char as well
                        p = nxt
                        continue
                    end
                elseif p == opts.escapechar
                    # previous char escaped this one
                    i = ii
                    p = c
                    continue
                end
            end
            if opts.includequotes
                i = ii
            end
            break
        elseif (!opts.includenewlines && isnewline(c))
            break
        end
        i = ii
        p = c
    end

    return R(_substring(T, str, i0, i-1)), i
end

@inline function _substring(::Type{String}, str, i, j)
    str[i:j]
end

if VERSION <= v"0.6.0-dev"
    # from lib/Str.jl
    @inline function _substring(::Type{Str}, str, i, j)
        Str(pointer(Vector{UInt8}(str))+(i-1), j-i+1)
    end
end

@inline function _substring{T<:SubString}(::Type{T}, str, i, j)
    T(str, i, j)
end

fromtype(::Type{StrRange}) = StringToken(StrRange)

@inline function alloc_string(str, r::StrRange)
    unsafe_string(_pointer(str, 1+r.offset), r.length)
end

@inline function _substring(::Type{StrRange}, str, i, j)
    StrRange(i-1, j-i+1)
end

export Quoted

immutable Quoted{T, S<:AbstractToken} <: AbstractToken{T}
    inner::S
    required::Bool
    stripwhitespaces::Bool
    includequotes::Bool
    includenewlines::Bool
    quotechar::Nullable{Char}
    escapechar::Nullable{Char}
end

function show(io::IO, q::Quoted)
    c = quotechar(q, default_opts)
    print(io, "$c")
    show(io, q.inner)
    print(io, "$c")
end

"""
`Quoted(inner::AbstractToken; <kwargs>...)`

# Arguments:
- `inner`: The token inside quotes to parse
- `required`: are quotes required for parsing to succeed? defaults to `false`
- `includequotes`: include the quotes in the output. Defaults to `false`
- `includenewlines`: include newlines that appear within quotes. Defaults to `true`
- `quotechar`: character to use to quote (default decided by `LocalOpts`)
- `escapechar`: character that escapes the quote char (default set by `LocalOpts`)
"""
function Quoted{S<:AbstractToken}(inner::S;
    required=false,
    stripwhitespaces=fieldtype(S)<:Number,
    includequotes=false,
    includenewlines=true,
    quotechar=Nullable{Char}(),   # This is to allow file-wide config
    escapechar=Nullable{Char}())

    T = fieldtype(S)
    Quoted{T,S}(inner, required, stripwhitespaces, includequotes,
                includenewlines, quotechar, escapechar)
end

@inline quotechar(q::Quoted, opts) = get(q.quotechar, opts.quotechar)
@inline escapechar(q::Quoted, opts) = get(q.escapechar, opts.escapechar)

Quoted(t::Type; kwargs...) = Quoted(fromtype(t); kwargs...)

function tryparsenext{T}(q::Quoted{T}, str, i, len, opts)
    if i > len
        q.required && @goto error
        # check to see if inner thing is ok with an empty field
        @chk2 x, i = tryparsenext(q.inner, str, i, len, opts) error
        @goto done
    end
    c, ii = next(str, i)
    quotestarted = false
    if quotechar(q, opts) == c
        quotestarted = true
        if !q.includequotes
            i = ii
        end

        if q.stripwhitespaces
            i = eatwhitespaces(str, i)
        end
    else
        q.required && @goto error
    end

    if quotestarted
        qopts = LocalOpts(quotechar(q, opts), false, quotechar(q, opts), escapechar(q, opts),
                         q.includequotes, q.includenewlines)
        @chk2 x, i = tryparsenext(q.inner, str, i, len, qopts)
    else
        @chk2 x, i = tryparsenext(q.inner, str, i, len, opts)
    end

    if i > len
        if quotestarted && !q.includequotes
            @goto error
        end
        @goto done
    end

    if q.stripwhitespaces
        i = eatwhitespaces(str, i)
    end
    c, ii = next(str, i)

    if quotestarted && !q.includequotes
        c != quotechar(q, opts) && @goto error
        i = ii
    end


    @label done
    return Nullable{T}(x), i

    @label error
    return Nullable{T}(), i
end

## Date and Time
immutable DateTimeToken{T,S<:DateFormat} <: AbstractToken{T}
    format::S
end

"""
    DateTimeToken(T, fmt::DateFormat)

Parse a date time string of format `fmt` into type `T` which is
either `Date`, `Time` or `DateTime`.
"""
DateTimeToken{S<:DateFormat}(T::Type, df::S) = DateTimeToken{T, S}(df)
DateTimeToken{S<:DateFormat}(df::S) = DateTimeToken{DateTime, S}(df)
fromtype(df::DateFormat) = DateTimeToken(DateTime, df)
fromtype(::Type{DateTime}) = DateTimeToken(DateTime, ISODateTimeFormat)
fromtype(::Type{Date}) = DateTimeToken(Date, ISODateFormat)

function fromtype(nd::Union{Nullable{DateFormat}, DataValue{DateFormat}})
    if !isnull(nd)
        NAToken(DateTimeToken(DateTime, get(nd)))
    else
        fromtype(DataValue{DateTime})
    end
end

function tryparsenext{T}(dt::DateTimeToken{T}, str, i, len, opts)
    R = Nullable{T}
    nt, i = tryparsenext_internal(T, str, i, len, dt.format, opts.endchar)
    if isnull(nt)
        return R(), i
    else
        return R(T(nt.value...)), i
    end
end

### Nullable

const nastrings_upcase = ["NA", "NULL", "N/A","#N/A", "#N/A N/A", "#NA",
                          "-1.#IND", "-1.#QNAN", "-NaN", "-nan",
                          "1.#IND", "1.#QNAN", "N/A", "NA", "NaN", "nan"]

const NA_STRINGS = sort!(vcat(nastrings_upcase, map(lowercase, nastrings_upcase)))

immutable NAToken{T, S<:AbstractToken} <: AbstractToken{T}
    inner::S
    emptyisna::Bool
    endchar::Nullable{Char}
    nastrings::Vector{String}
end

"""
`NAToken(inner::AbstractToken; options...)`

Parses a Nullable item.

# Arguments
- `inner`: the token to parse if non-null.
- `emptyisna`: should an empty item be considered NA? defaults to true
- `nastrings`: strings that are to be considered NA. Defaults to `$NA_STRINGS`
"""
function NAToken{S}(
    inner::S,
  ; emptyisna=true
  , endchar=Nullable{Char}()
  , nastrings=NA_STRINGS)

    T = fieldtype(inner)
    NAToken{DataValue{T}, S}(inner, emptyisna, endchar, nastrings)
end

function show(io::IO, na::NAToken)
    show(io, na.inner)
    print(io, "?")
end

endchar(na::NAToken, opts) = get(na.endchar, opts.endchar)

function tryparsenext{T}(na::NAToken{T}, str, i, len, opts)
    R = Nullable{T}
    i = eatwhitespaces(str, i)
    if i > len
        if na.emptyisna
            @goto null
        else
            @goto error
        end
    end

    c, ii=next(str,i)
    if (c == endchar(na, opts) || isnewline(c)) && na.emptyisna
       @goto null
    end

    if isa(na.inner, Unknown)
        @goto maybe_null
    end
    @chk2 x,ii = tryparsenext(na.inner, str, i, len, opts) maybe_null

    @label done
    return R(T(x)), ii

    @label maybe_null
    naopts = LocalOpts(endchar(na,opts), opts.spacedelim, opts.quotechar,
                       opts.escapechar, false, opts.includenewlines)
    @chk2 nastr, ii = tryparsenext(StringToken(String), str, i, len, naopts)
    if !isempty(searchsorted(na.nastrings, nastr))
        i=ii
        i = eatwhitespaces(str, i)
        @goto null
    end
    return R(), i

    @label null
    return R(T()), i

    @label error
    return R(), i
end

fromtype{N<:Nullable}(::Type{N}) = NAToken(fromtype(eltype(N)))
fromtype{N<:DataValue}(::Type{N}) = NAToken(fromtype(eltype(N)))

### Field parsing

@compat abstract type AbstractField{T} <: AbstractToken{T} end # A rocord is a collection of abstract fields

immutable Field{T,S<:AbstractToken} <: AbstractField{T}
    inner::S
    ignore_init_whitespace::Bool
    ignore_end_whitespace::Bool
    eoldelim::Bool
end

function Field{S}(inner::S; ignore_init_whitespace=true, ignore_end_whitespace=true, eoldelim=false)
    T = fieldtype(inner)
    Field{T,S}(inner, ignore_init_whitespace, ignore_end_whitespace, eoldelim)
end

function Field(f::Field; inner=f.inner, ignore_init_whitespace=f.ignore_init_whitespace,
                  ignore_end_whitespace=f.ignore_end_whitespace,
                  eoldelim=f.eoldelim)
    T = fieldtype(inner)
    Field{T,typeof(inner)}(inner, ignore_init_whitespace,
                           ignore_end_whitespace, eoldelim)
end

function swapinner(f::Field, inner::AbstractToken;
        ignore_init_whitespace= f.ignore_end_whitespace
      , ignore_end_whitespace=f.ignore_end_whitespace
      , eoldelim=f.eoldelim
  )
    Field(inner;
        ignore_init_whitespace=ignore_end_whitespace
      , ignore_end_whitespace=ignore_end_whitespace
      , eoldelim=eoldelim
     )

end

function tryparsenext{T}(f::Field{T}, str, i, len, opts)
    R = Nullable{T}
    i > len && @goto error
    if f.ignore_init_whitespace
        while i <= len
            @inbounds c, ii = next(str, i)
            !isspace(c) && break
            i = ii
        end
    end
    @chk2 res, i = tryparsenext(f.inner, str, i, len, opts)

    if f.ignore_end_whitespace
        i0 = i
        while i <= len
            @inbounds c, ii = next(str, i)
            !opts.spacedelim && opts.endchar == '\t' && c == '\t' && (i =ii; @goto done)
            !isspace(c) && c != '\t' && break
            i = ii
        end

        opts.spacedelim && i > i0 && @goto done
    end
    # todo don't ignore whitespace AND spacedelim

    if i > len
        if f.eoldelim
            @goto done
        else
            @goto error
        end
    end

    @inbounds c, ii = next(str, i)
    opts.spacedelim && (isspace(c) || c == '\t') && (i=ii; @goto done)
    !opts.spacedelim && opts.endchar == c && (i=ii; @goto done)

    if f.eoldelim
        if c == '\r'
            i=ii
            if i <= len
                @inbounds c, ii = next(str, i)
                if c == '\n'
                    i=ii
                end
            end
            @goto done
        elseif c == '\n'
            i=ii
            if i <= len
                @inbounds c, ii = next(str, i)
                if c == '\r'
                    i=ii
                end
            end
            @goto done
        end
    end

    @label error
    return R(), i

    @label done
    if R <: Nullable{DataValue{Union{}}}
        # optimization to remove allocation
        return nullableNA, i
    end
    return R(res), i
end

