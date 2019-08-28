module TestParallelReduce
include("preamble.jl")

struct Recorder
    records
    lock
end

Recorder() = Recorder([], Threads.SpinLock())

function (recorder::Recorder)(x)
    try
        lock(recorder.lock)
        push!(recorder.records, x)
        return x
    finally
        unlock(recorder.lock)
    end
end

@testset "early termination (runtime)" begin
    recorder = Recorder()
    records = recorder.records
    @test reduce(right, Map(recorder) |> ReduceIf(==(1)), 1:32;
                 basesize=1) === 1
    if VERSION >= v"1.3-alpha"
        if Threads.nthreads() == 1
            @test length(records) == 1
        else
            # Not sure if this safe, but let's check if _some_
            # tasks are canceled.
            @test length(records) < sum(2 .^ (0:5))
            # (though it seems `length(records)` is always 1?)
        end
    end
end

@testset "early termination (grid)" begin
    @testset for needle in 1:20, len in 1:20
        @test reduce(right, ReduceIf(x -> x >= needle), 1:len; basesize=1) ==
            min(needle, len)
    end
end

@testset "early termination (shuffle)" begin
    @testset for seed in rand(UInt32, 10), p in Any[50, 95, 99, Inf]
        rng = MersenneTwister(seed)
        basesize = 16
        xs = collect(enumerate(rand(rng, 1:100, 100 * basesize)))
        xf = ReduceIf(x -> x[2] >= p)
        @test reduce(right, xf, xs; basesize=basesize) == foldl(right, xf, xs)
    end
end

end  # module
