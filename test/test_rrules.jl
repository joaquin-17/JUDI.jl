# Gradient tests for adjoint extended modeling
# Author: Mathias Louboutin, mathias.louboutin@gmail.com
# April 2022
using Flux
import JUDI: judiPropagator, LazyPropagation
import Base.Broadcast: broadcasted
Flux.Random.seed!(2022)

### Model
nsrc = 1
dt = 1f0

model, model0, dm = setup_model(tti, viscoacoustic, 2)
m, m0 = model.m.data, model0.m.data
q, srcGeometry, recGeometry, f0 = setup_geom(model; nsrc=nsrc, dt=dt)

# Common op
Pr = judiProjection(recGeometry)
Ps = judiProjection(srcGeometry)
Pw = judiLRWF(dt, q.data[1])

function GenSimSourceMulti(xsrc_index, zsrc_index, nsrc, n)
    weights = zeros(Float32, n[1], n[2], 1, nsrc)
    for j=1:nsrc
        weights[xsrc_index[j], zsrc_index[j], 1, j] = 1f0
    end
    return weights
end

randx(x::Array{Float32}) = x .* (1 .+ randn(Float32, size(x)))
perturb(x::Vector{T}) where T = circshift(x, rand(1:20))
perturb(x::Array{T, N}) where {T, N} = circshift(x, (rand(1:20), zeros(N-1)...))
perturb(x::judiVector) = judiVector(x.geometry, [randx(x.data[i]) for i=1:x.nsrc])
reverse(x::judiVector) = judiVector(x.geometry, [x.data[i][end:-1:1, :] for i=1:x.nsrc])

misfit_objective_2p(d_obs, q0, m0, F) = .5f0*norm(F(m0, q0) - d_obs)^2
misfit_objective_1p(d_obs, q0, m0, F) = .5f0*norm(F(m0)*q0 - d_obs)^2
    
function loss(misfit, d_obs, q0, m0, F)
    local ϕ
    # Reshape as ML size if returns array
    d_obs = F.options.return_array ? reshape(d_obs, F.rInterpolation, F.model; with_batch=true) : d_obs
    # Misfit and gradient
    g = gradient(Flux.params(q0, m0)) do
        ϕ = misfit(d_obs, q0, m0, F)
        return ϕ
    end
    return ϕ, g[q0], g[m0]
end

xsrc_index, zsrc_index = rand(30:model.n[1]-30, nsrc), rand(30:model.n[2]-30, nsrc)
w = GenSimSourceMulti(xsrc_index, zsrc_index, nsrc, model.n);
# Put the point source at the same location for easy comparison
q.geometry.xloc[1] .= (xsrc_index[1] - 1) * model.d[1]
q.geometry.zloc[1] .= (zsrc_index[1] - 1) * model.d[2]

sinput = zip(["Point", "Extended"], [Ps, Pw], (q, w))
#####################################################################################
ftol = sqrt(eps(1f0))

@testset "AD correctness check return_array:$(ra)" for ra in [true, false]
    opt = Options(return_array=ra, sum_padding=true, f0=f0)
    A_inv = judiModeling(model; options=opt)
    A_inv0 = judiModeling(model0; options=opt)
    @testset "AD correctness check source type: $(stype)" for (stype, Pq, q) in sinput
        @timeit TIMEROUTPUT "$(stype) source AD, array=$(ra)" begin
            printstyled("$(stype) source AD test ra: $(ra) \n", color=:blue)
            # Linear operators
            q0 = perturb(q)
            # Operators
            F = Pr*A_inv*adjoint(Pq)
            F0 = Pr*A_inv0*adjoint(Pq)

            d_obs = F(m, q)
            # PDE accept model as input but AD expect the actual model param (model.m)
            d_obs2 = F(model, q)
            @test d_obs ≈ d_obs2 rtol=ftol

            J = judiJacobian(F0, q0)
            gradient_m = adjoint(J)*(F(m0, q0) - d_obs)
            gradient_m2 = adjoint(J)*(F(model0.m, q0) - d_obs)
            @test gradient_m ≈ gradient_m2 rtol=ftol

            # Reshape d_obs into ML size (nt, nrec, 1, nsrc)
            d_obs = ra ? reshape(d_obs, Pr, model; with_batch=true) : d_obs

            # Gradient with m array
            gs_inv = gradient(x -> misfit_objective_2p(d_obs, q0, x, F), m0)
            if ~ra
                gs_inv1 = gradient(x -> misfit_objective_1p(d_obs, q0, x, F), model0.m)
                @test gs_inv[1][:] ≈ gs_inv1[1][:] rtol=ftol
            end
            # Gradient with m PhysicalParameter
            gs_inv2 = gradient(x -> misfit_objective_2p(d_obs, q0, x, F), model0.m)
            @test gs_inv[1][:] ≈ gs_inv2[1][:] rtol=ftol

            if ~ra
                gs_inv21 = gradient(x -> misfit_objective_1p(d_obs, q0, x, F), model0.m)
                @test gs_inv21[1][:] ≈ gs_inv2[1][:] rtol=ftol
            end

            g1 = vec(gradient_m)
            g2 = vec(gs_inv[1])

            @test isapprox(norm(g1 - g2) / norm(g1 + g2), 0f0; atol=ftol)
            @test isapprox(dot(g1, g2)/norm(g1)^2,1f0;rtol=ftol)
            @test isapprox(dot(g1, g2)/norm(g2)^2,1f0;rtol=ftol)
        end
    end
end


@testset "AD Gradient test return_array=$(ra)" for ra in [true, false]
    opt = Options(return_array=ra, sum_padding=true, f0=f0, dt_comp=dt)
    F = judiModeling(model; options=opt)
    ginput = zip(["Point", "Extended"], [Pr*F*Ps', Pr*F*Pw'], (q, w))
    @testset "Gradient test: $(stype) source" for (stype, F, q) in ginput
        @timeit TIMEROUTPUT "$(stype) source gradient, array=$(ra)" begin
            # Initialize source for source perturbation
            q0 = perturb(q)
            # Data and source perturbation
            d, dq = F*q, q-q0

            misf = ra ? [(2, misfit_objective_2p)] : [(1, misfit_objective_1p), (2, misfit_objective_2p)]
            m00 = ra ? m0 : model0.m
            #####################################################################################
            for (mi, misfit) in misf
                printstyled("$(stype) source gradient test for $(mi)-input operator\n"; color = :blue)
                f0, gq, gm = loss(misfit, d, q0, m00, F)
                # Gradient test for extended modeling: source
                printstyled("\nGradient test source $(stype) source, array=$(ra)\n"; color = :blue)
                grad_test(x-> misfit(d, x, m00, F), q0, dq, gq)
    
                # Gradient test for extended modeling: model
                printstyled("\nGradient test model $(stype) source, array=$(ra)\n"; color = :blue)
                grad_test(x-> misfit(d, q0, x, F), m00, dm, gm)
            end
        end
    end
end


@testset "AD Gradient test Jacobian w.r.t q with $(nlayer) layers, tti $(tti), viscoacoustic $(viscoacoustic), freesurface $(fs)" begin
    @timeit TIMEROUTPUT "Jacobian gradient w.r.t source" begin
        opt = Options(sum_padding=true, free_surface=fs)
        J = judiJacobian(judiModeling(model0, srcGeometry, recGeometry; options=opt), q)
        q0 = judiVector(q.geometry, ricker_wavelet(srcGeometry.t[1], srcGeometry.dt[1], 0.0125f0))
        dq = q0 - q
        δd = J*dm
        rtm = J'*δd
        # derivative of J w.r.t to `q`
        printstyled("Gradient J(q) w.r.t q\n"; color = :blue)
        f0q, gm, gq = loss(misfit_objective_1p, δd, dm, q0, J)
        @test isa(gm, JUDI.LazyPropagation)
        @test isa(JUDI.eval_prop(gm), PhysicalParameter)
        grad_test(x-> misfit_objective_1p(δd, dm, x, J), q0, dq, gq)

        printstyled("Gradient J'(q) w.r.t q\n"; color = :blue)
        f0qt, gd, gqt = loss(misfit_objective_1p, rtm, δd, q0, adjoint(J))
        @test isa(gd, JUDI.LazyPropagation)
        @test isa(JUDI.eval_prop(gd), judiVector)
        grad_test(x-> misfit_objective_1p(rtm, δd, x, adjoint(J)), q0, dq, gqt)
    end
end

#####################################################################################
struct TestPropagator{D, O} <: judiPropagator{D, O}
    v::D
end

Base.:*(T::TestPropagator{D, O}, x::Vector{D}) where {D, O} = T.v .* x
Base.:*(T::TestPropagator{D, O}, x::Matrix{D}) where {D, O} = T.v .* x

T1 = TestPropagator{Float32, :test}(2)
T2 = TestPropagator{Float32, :test}(3)

xtest1 = randn(Float32, 16)
xtest2 = randn(Float32, 16)
xtest3 = randn(Float32, 4, 4)

xeval = reshape(2 .* xtest1, 4, 4)
xeval2 = reshape(3 .* xtest2, 4, 4)

p = x -> reshape(x, 4, 4)

LP1 = LazyPropagation(p, T1, xtest1)
LP2 = LazyPropagation(p, T2, xtest2)


@testset "LazyPropagation tests" begin
    @timeit TIMEROUTPUT "LazyPropagation" begin
        # Manipulation
        @test collect(reshape(LP1, 8, 2)) == reshape(xeval, 8, 2)
        @test JUDI.eval_prop(LP1) == reshape(xeval, 4, 4)
        @test collect(LP1) == reshape(xeval, 4, 4)
        # Arithmetic
        for op in [Base.:+, Base.:-, Base.:*, Base.:/]
            @test op(LP1, xtest3) ≈ op(xeval, xtest3)
            @test op(xtest3, LP1) ≈ op(xtest3, xeval)
            @test op(LP1, LP2) ≈ op(xeval, xeval2)
            @test op.(LP1, LP2) ≈ op.(xeval, xeval2)
            @test op.(LP1, xtest3) ≈ op.(xeval, xtest3)
            @test op.(xtest3, LP2) ≈ op.(xtest3, xeval2)
        end
        @test LP1.^2 ≈ xeval.^2
        @test T2 * LP1 ≈ reshape(6 .* xtest1, 4, 4)
        @test collect(adjoint(LP1)) ≈ collect(adjoint(xeval))
        @test norm(LP1) ≈ norm(xeval)

        copyto!(xtest3, LP1)
        @test xtest3 ≈ xeval
    end
end


#####################################################################################
# Preconditioners
@testset "Preconditionners AD tests" begin
    @timeit TIMEROUTPUT "Preconditionners AD" begin
        T = judiDepthScaling(model)
        b = T*model.m
        g = gradient(x->.5f0*norm(T*x - b)^2, model0.m)
        @test g[1] ≈ T'*(T*model0.m - b)
    end
end