#!/bin/bash
# -*- mode: julia -*-
#=
JULIA="${JULIA:-julia --color=yes --startup-file=no}"
export JULIA_PROJECT="$(dirname ${BASH_SOURCE[0]})"

set -ex
${JULIA} -e 'using Pkg; Pkg.instantiate();
             Pkg.develop(PackageSpec(path=pwd()))'
exec ${JULIA} "${BASH_SOURCE[0]}" "$@"
=#

include("utils.jl")
using Literate
transducers_literate()
transducers_makedocs()
deploydocs(;
    repo="github.com/tkf/Transducers.jl",
)
