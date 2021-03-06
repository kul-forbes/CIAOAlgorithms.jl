# # tests for lasso: 1/2\|Ax-b\|^2 + λ \|x\|_1

@testset "Lasso ($T)" for T in [Float32, Float64, ComplexF32, ComplexF64]
    using Test
    using LinearAlgebra
    using CIAOAlgorithms
    using ProximalOperators
    using Base.Iterators: take
    using Random

    Random.seed!(0)
    R = real(T)

    # problem definition
    N, n = 6, 3 # A in R^{N x n}   
    p = 2 # nonzeros in the solution

    y_star = rand(R, N)
    y_star ./= norm(y_star) # y^star
    C = rand(R, N, n) .* 2 .- 1
    CTy = abs.(C' * y_star)
    # indices with decreasing order by abs
    perm = sortperm(CTy, rev = true)

    rho, λ = R(10), R(1)
    alpha = zeros(T, n)
    for i = 1:n
        if i <= p
            alpha[perm[i]] = λ / CTy[perm[i]]
        else
            alpha[perm[i]] = (CTy[perm[i]] < 0.1 * λ) ? λ : λ * rand() / CTy[perm[i]]
        end
    end
    A = C * diagm(0 => alpha)   # scaling the columns of Cin
    # generate the solution
    x_star = zeros(T, n)
    for i = 1:n
        if i <= p
            x_star[perm[i]] = rand() * rho / sqrt(p) * sign(dot(A[:, perm[i]], y_star))
        end
    end
    b = A * x_star + y_star

    # cost function
    cost_lasso(x) = norm(A * x - b)^2 / 2 + λ * norm(x, 1)

    f_star = cost_lasso(x_star)

    # preparations for the solver 
    F = Vector{LeastSquares}(undef, 0)
    L = Vector{R}(undef, 0)
    for i = 1:N
        tempA = A[i:i, :]
        f = LeastSquares(tempA, b[i:i], R(N))
        Lf = opnorm(tempA)^2 * N
        push!(F, f)
        push!(L, Lf)
    end
    g = NormL1(λ)
    x0 = zeros(T, n)

    maxit = 1000
    tol = 1e-4

    @testset "Finito" begin
        # sweeping 1, 2, 3 for randomined, cyclic and shuffled sampling strategies, respectively.

        ## test the solver
        # basic finito
        @testset "basic Finito" for sweeping in collect(1:3)
            solver = CIAOAlgorithms.Finito{R}(maxit = maxit, sweeping = sweeping)
            x_finito, it_finito = solver(x0, F = F, g = g, L = L, N = N)
            @test cost_lasso(x_finito) - f_star < tol
            @test eltype(x_finito) == T
        end

        # limited memory finito 
        @testset "LFinito" for sweeping in collect(2:3)
            # @testset "cyclical" begin
            solver =
                CIAOAlgorithms.Finito{R}(maxit = maxit, sweeping = sweeping, LFinito = true)
            x_finito, it_finito = solver(x0, F = F, g = g, L = L, N = N)
            @test cost_lasso(x_finito) - f_star < tol
            @test eltype(x_finito) == T
        end

        # # adaptive variant 
        @testset "adaptive finito" for sweeping in collect(1:3)
            solver = CIAOAlgorithms.Finito{R}(
                maxit = maxit,
                tol = R(1e-5),
                sweeping = sweeping,
                adaptive = true,
            )
            x_finito, it_finito = solver(x0, F = F, g = g, L = L, N = N)
            @test cost_lasso(x_finito) - f_star < tol
            @test eltype(x_finito) == T
        end

        # basic finito with minibatch 
        vec_ref = [(1, 2), (2, 2), (3, 3)] # different samplings and batch sizes 
        @testset "Finito_minibatch" for (sweeping, batch) in vec_ref
            solver = CIAOAlgorithms.Finito{R}(
                maxit = maxit,
                sweeping = sweeping,
                minibatch = (true, batch),
            )
            x_finito, it_finito = solver(x0, F = F, g = g, L = L, N = N)
            @test cost_lasso(x_finito) - f_star < tol
            @test eltype(x_finito) == T
        end

        # limited memory finito with minibatch 
        vec_ref = [(2, 1), (2, 2), (3, 3)] # different samplings and batch sizes 
        @testset "LFinito_minibatch" for (sweeping, batch) in vec_ref
            solver = CIAOAlgorithms.Finito{R}(
                maxit = maxit,
                sweeping = sweeping,
                LFinito = true,
                minibatch = (true, batch),
            )
            x_finito, it_finito = solver(x0, F = F, g = g, L = L, N = N)
            @test cost_lasso(x_finito) - f_star < tol
            @test eltype(x_finito) == T
        end

        # test with user defined stepsizes
        @testset "γ and L as scalars" begin
            @testset "randomized" begin
                γ = N / maximum(L)
                solver = CIAOAlgorithms.Finito{R}(maxit = maxit, γ = γ)
                x_finito, it_finito = solver(x0, F = F, g = g, L = L, N = N)
                @test cost_lasso(x_finito) - f_star < tol
            end
            @testset "cyclic" begin
                solver = CIAOAlgorithms.Finito{R}(maxit = maxit)
                x_finito, it_finito = solver(x0, F = F, g = g, L = maximum(L), N = N)
                @test cost_lasso(x_finito) - f_star < tol
            end
        end

        ## test the iterator 
        vec_ref = [(1, false, false), (2, false, false), (3, false, true), (3, true, false)]
        @testset "the iterator" for (sweeping, LFinito, adaptive) in vec_ref
            solver = CIAOAlgorithms.Finito{R}(
                sweeping = sweeping,
                LFinito = LFinito,
                adaptive = adaptive,
            )
            iter = CIAOAlgorithms.iterator(solver, x0, F = F, g = g, L = L, N = N)
            @test iter.x0 === x0

            for state in take(iter, 2)
                @test solution(state) === state.z
                @test eltype(solution(state)) == T
            end
        end
    end


    @testset "SVRG" begin

        ## test the solver
        γ = 1 / (7 * maximum(L))
        @testset "SVRG-Base" begin
            solver = CIAOAlgorithms.SVRG{R}(maxit = maxit, γ = γ)
            x_SVRG, it_SVRG = solver(x0, F = F, g = g, N = N)
            @test cost_lasso(x_SVRG) - f_star < tol
            @test eltype(x_SVRG) == T
        end
        @testset "SVRG++" begin
            solver = CIAOAlgorithms.SVRG{R}(maxit = 16, γ = γ, m = 1, plus = true)
            x_SVRG, it_SVRG = solver(x0, F = F, g = g, N = N)
            @test cost_lasso(x_SVRG) - f_star < tol
            @test eltype(x_SVRG) == T
        end

        # test the iterator 
        @testset "the iterator" begin
            solver = CIAOAlgorithms.SVRG{R}(γ = γ)
            iter = CIAOAlgorithms.iterator(solver, x0, F = F, g = g, N = N)
            @test iter.x0 === x0

            for state in take(iter, 2)
                @test solution(state) === state.z_full
                @test eltype(solution(state)) == T
            end
            next = iterate(iter) # next = (state, state)
            # one iteration with the solver 
            solver = CIAOAlgorithms.SVRG{R}(γ = γ, maxit = 1)
            x_finito, it_finito = solver(x0, F = F, g = g, L = L, N = N)
            @test solution(next[2]) == x_finito
        end
    end

    @testset "SAGA" begin

        ## test the solver
        @testset "SAGA-Base" begin
            solver = CIAOAlgorithms.SAGA{R}(maxit = maxit)
            x_SAGA, it_SAGA = solver(x0, F = F, g = g, N = N, L = L)
            @test cost_lasso(x_SAGA) - f_star < tol
            @test eltype(x_SAGA) == T
        end
        @testset "SAGA-stepsize" begin
            γ = 1 / (3 * maximum(L))
            solver = CIAOAlgorithms.SAGA{R}(maxit = maxit, γ = γ)
            x_SAGA, it_SAGA = solver(x0, F = F, g = g, N = N)
            @test cost_lasso(x_SAGA) - f_star < tol
            @test eltype(x_SAGA) == T
        end

        # test the iterator 
        @testset "the iterator" begin
            γ = 1 / (3 * maximum(L))
            solver = CIAOAlgorithms.SAGA{R}(γ = γ)
            iter = CIAOAlgorithms.iterator(solver, x0, F = F, g = g, N = N)
            @test iter.x0 === x0

            for state in take(iter, 2)
                @test solution(state) === state.z
                @test eltype(solution(state)) == T
            end
            next = iterate(iter) # next = (state, state)
            # one iteration with the solver 
            solver = CIAOAlgorithms.SAGA{R}(γ = γ, maxit = 1)
            x_finito, it_finito = solver(x0, F = F, g = g, L = L, N = N)
            @test solution(next[2]) == x_finito
        end
    end

    @testset "SAG" begin
        # note that proximal SAG may not be theoretically convergent
        maxit = 10000
        ## test the solver
        @testset "SAG-Base" begin
            solver = CIAOAlgorithms.SAG(R, maxit = maxit)
            x_SAG, it_SAG = solver(x0, F = F, g = g, N = N, L = L)
            @test cost_lasso(x_SAG) - f_star < tol
            @test eltype(x_SAG) == T
        end
        @testset "SAG" begin
            γ = 1 / (16 * maximum(L))
            solver = CIAOAlgorithms.SAG(R, maxit = maxit, γ = γ)
            x_SAG, it_SAG = solver(x0, F = F, g = g, N = N)
            @test cost_lasso(x_SAG) - f_star < tol
            @test eltype(x_SAG) == T
        end

        # test the iterator 
        @testset "the iterator" begin
            γ = 1 / (16 * maximum(L))
            solver = CIAOAlgorithms.SAG(R, γ = γ)
            iter = CIAOAlgorithms.iterator(solver, x0, F = F, g = g, N = N)
            @test iter.x0 === x0

            for state in take(iter, 2)
                @test solution(state) === state.z
                @test eltype(solution(state)) == T
            end
            next = iterate(iter) # next = (state, state)
            # one iteration with the solver 
            solver = CIAOAlgorithms.SAG(R, γ = γ, maxit = 1)
            x_finito, it_finito = solver(x0, F = F, g = g, L = L, N = N)
            @test solution(next[2]) == x_finito
        end
    end
end
