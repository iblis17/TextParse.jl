__precompile__()

module TextParse

using DataValues
using Base.Test

include("lib/compat.jl")
include("util.jl")
include("field.jl")
include("record.jl")

include("guesstype.jl")
include("csv.jl")

end # module
