"""
    reduce(step, xf, reducible; init, simd) :: T

Possibly parallel version of [`foldl`](@ref).  The "bottom"
reduction function `step(::T, ::T) :: T` must be associative and
`init` must be its identity element.

Transducers composing `xf` must be stateless and non-terminating
(e.g., [`Map`](@ref), [`Filter`](@ref), [`Cat`](@ref), etc.) except
for [`ScanEmit`](@ref).  Note that [`Scan`](@ref) is not supported
(although possible in theory).

See [`foldl`](@ref).
"""
Base.reduce

"""
    mapreduce(xf, step, reducible; init, simd)

!!! warning

    `mapreduce` exists primary for backward compatibility.  It is
    recommended to use `reduce`.

Like [`reduce`](@ref) but `step` is _not_ automatically wrapped by
[`Completing`](@ref).
"""
Base.mapreduce

struct SizedReducible{T} <: Reducible
    reducible::T
    basesize::Int
end

foldable(reducible::SizedReducible) = reducible.reducible

issmall(reducible::SizedReducible) =
    length(reducible.reducible) <= max(reducible.basesize, 1)

function halve(reducible::SizedReducible)
    left, right = halve(reducible.reducible)
    return (
        SizedReducible(left, reducible.basesize),
        SizedReducible(right, reducible.basesize),
    )
end

function halve(arr::AbstractArray)
    # TODO: support "slow" arrays
    mid = length(arr) ÷ 2
    left = @view arr[firstindex(arr):firstindex(arr) - 1 + mid]
    right = @view arr[firstindex(arr) + mid:end]
    return (left, right)
end

struct TaskContext
    listening::Vector{Threads.Atomic{Bool}}
    cancellables::Vector{Threads.Atomic{Bool}}
end

TaskContext() = TaskContext([], [])

function splitcontext(ctx::TaskContext)
    c = Threads.Atomic{Bool}(false)
    return (
        fg = TaskContext(ctx.listening, vcat(ctx.cancellables, c)),
        bg = TaskContext(vcat(ctx.listening, c), ctx.cancellables),
    )
end

function should_abort(ctx::TaskContext)
    for c in ctx.listening
        c[] && return true
    end
    return false
end

function cancel!(ctx::TaskContext)
    for c in ctx.cancellables
        c[] = true
    end
end

function transduce_assoc(
    xform::Transducer, step, init, coll;
    simd::SIMDFlag = Val(false),
    basesize = Threads.nthreads() == 1 ? typemax(Int) : 512,
)
    reducible = SizedReducible(coll, basesize)
    rf = maybe_usesimd(Reduction(xform, step), simd)
    @static if VERSION >= v"1.3-alpha"
        acc = @return_if_reduced _reduce(TaskContext(), rf, init, reducible)
    else
        acc = @return_if_reduced _reduce_threads_for(rf, init, reducible)
    end
    return complete(rf, acc)
end

function _reduce(ctx, rf, init, reducible::Reducible)
    should_abort(ctx) && return init
    if issmall(reducible)
        acc = foldl_nocomplete(rf, _start_init(rf, init), foldable(reducible))
        if acc isa Reduced
            cancel!(ctx)
        end
        return acc
    else
        left, right = halve(reducible)
        fg, bg = splitcontext(ctx)
        task = @spawn _reduce(bg, rf, init, right)
        a0 = _reduce(fg, rf, init, left)
        b0 = fetch(task)
        a = @return_if_reduced a0
        b = @return_if_reduced b0
        should_abort(ctx) && return a  # slight optimization
        return combine(rf, a, b)
    end
end

function _reduce_threads_for(rf, init, reducible::SizedReducible{<:AbstractArray})
    arr = reducible.reducible
    basesize = reducible.basesize
    nthreads = max(
        1,
        basesize <= 1 ? length(arr) : length(arr) ÷ basesize
    )
    if nthreads == 1
        return foldl_nocomplete(rf, _start_init(rf, init), arr)
    else
        w = length(arr) ÷ nthreads
        results = Vector{Any}(undef, nthreads)
        Threads.@threads for i in 1:nthreads
            if i == nthreads
                chunk = @view arr[(i - 1) * w + 1:end]
            else
                chunk = @view arr[(i - 1) * w + 1:i * w]
            end
            results[i] = foldl_nocomplete(rf, _start_init(rf, init), chunk)
        end
        i = findfirst(isreduced, results)
        i === nothing || return results[i]
        # It can be done in `log2(n)` for loops but it's not clear if
        # `combine` is compute-intensive enough so that launching
        # threads is worth enough.  Let's merge the `results`
        # sequentially for now.
        c = foldl(results) do a, b
            combine(rf, a, b)
        end
        return c
    end
end

# AbstractArray for disambiguation
Base.mapreduce(xform::Transducer, step, itr::AbstractArray;
               init = MissingInit(), kwargs...) =
    unreduced(transduce_assoc(xform, step, init, itr; kwargs...))

Base.mapreduce(xform::Transducer, step, itr;
               init = MissingInit(), kwargs...) =
    unreduced(transduce_assoc(xform, step, init, itr; kwargs...))

Base.reduce(step, xform::Transducer, itr; kwargs...) =
    mapreduce(xform, Completing(step), itr; kwargs...)
