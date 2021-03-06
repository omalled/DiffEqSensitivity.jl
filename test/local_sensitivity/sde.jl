using Test, LinearAlgebra
using OrdinaryDiffEq
using DiffEqSensitivity, StochasticDiffEq, DiffEqBase
using ForwardDiff, Calculus, ReverseDiff
using Random
import Tracker, Zygote

@info "SDE Adjoints"

seed = 100
Random.seed!(seed)
abstol = 1e-4
reltol = 1e-4

u₀ = [0.5]
tstart = 0.0
tend = 0.1
dt = 0.005
trange = (tstart, tend)
t = tstart:dt:tend
tarray = collect(t)

function g(u,p,t)
  sum(u.^2.0/2.0)
end

function dg!(out,u,p,t,i)
  (out.=-u)
end

p2 = [1.01,0.87]

@testset "SDE oop Tests" begin
  f_oop_linear(u,p,t) = p[1]*u
  σ_oop_linear(u,p,t) = p[2]*u

  function f_oop_linear(u::Tracker.TrackedArray,p,t)
    dx = p[1]*u[1]
    Tracker.collect([dx])
  end

  function σ_oop_linear(u::Tracker.TrackedArray,p,t)
    dx = p[2]*u[1]
    Tracker.collect([dx])
  end

  p = [1.01,0.0]

  # generate ODE adjoint results

  prob_oop_ode = ODEProblem(f_oop_linear,u₀,(tstart,tend),p)
  sol_oop_ode = solve(prob_oop_ode,Tsit5(),saveat=t,abstol=abstol,reltol=reltol)
  res_ode_u0, res_ode_p = adjoint_sensitivities(sol_oop_ode,Tsit5(),dg!,t
    ,abstol=abstol,reltol=reltol,sensealg=BacksolveAdjoint())

  function G(p)
    tmp_prob = remake(prob_oop_ode,u0=eltype(p).(prob_oop_ode.u0),p=p,
                    tspan=eltype(p).(prob_oop_ode.tspan),abstol=abstol, reltol=reltol)
    sol = solve(tmp_prob,Tsit5(),saveat=Array(t),abstol=abstol, reltol=reltol)
    res = g(sol,p,nothing)
  end
  res_ode_forward = ForwardDiff.gradient(G,p)
  #res_ode_reverse = ReverseDiff.gradient(G,p)

  res_ode_trackeru0, res_ode_trackerp = Zygote.gradient((u0,p)->sum(solve(prob_oop_ode,Tsit5();u0=u0,p=p,abstol=abstol,reltol=reltol,saveat=Array(t),sensealg=TrackerAdjoint()).^2.0/2.0),u₀,p)

  @test isapprox(res_ode_forward[1], sum(@. u₀^2*exp(2*p[1]*t)*t), rtol = 1e-4)
  #@test isapprox(res_ode_reverse[1], sum(@. u₀^2*exp(2*p[1]*t)*t), rtol = 1e-4)
  @test isapprox(res_ode_p'[1], sum(@. u₀^2*exp(2*p[1]*t)*t), rtol = 1e-4)
  @test isapprox(res_ode_p', res_ode_trackerp, rtol = 1e-4)

  # SDE adjoint results (with noise == 0, so should agree with above)

  Random.seed!(seed)
  prob_oop_sde = SDEProblem(f_oop_linear,σ_oop_linear,u₀,trange,p)
  sol_oop_sde = solve(prob_oop_sde,RKMil(interpretation=:Stratonovich),dt=1e-4,adaptive=false,save_noise=true)
  res_sde_u0, res_sde_p = adjoint_sensitivities(sol_oop_sde,
    EulerHeun(),dg!,t,dt=1e-2,sensealg=BacksolveAdjoint())

  @info res_sde_p


  function GSDE1(p)
    Random.seed!(seed)
    tmp_prob = remake(prob_oop_sde,u0=eltype(p).(prob_oop_sde.u0),p=p,
                    tspan=eltype(p).(prob_oop_sde.tspan))
    sol = solve(tmp_prob,RKMil(interpretation=:Stratonovich),dt=tend/10000,adaptive=false,sensealg=DiffEqBase.SensitivityADPassThrough(),saveat=t)
    A = convert(Array,sol)
    res = g(A,p,nothing)
  end
  res_sde_forward = ForwardDiff.gradient(GSDE1,p)
  res_sde_reverse = ReverseDiff.gradient(GSDE1,p)

  res_sde_trackeru0, res_sde_trackerp = Zygote.gradient((u0,p)->sum(solve(prob_oop_sde,RKMil(interpretation=:Stratonovich),dt=tend/1400,adaptive=false,u0=u0,p=p,saveat=Array(t),sensealg=TrackerAdjoint()).^2.0/2.0),u₀,p)

  noise = vec((@. sol_oop_sde.W(tarray)))
  Wfix = [W[1][1] for W in noise]
  @test isapprox(res_sde_forward[1], sum(@. u₀^2*exp(2*p[1]*t)*t), rtol = 1e-4)
  @test isapprox(res_sde_reverse[1], sum(@. u₀^2*exp(2*p[1]*t)*t), rtol = 1e-4)
  @test isapprox(res_sde_p'[1], sum(@. u₀^2*exp(2*p[1]*t)*t), rtol = 1e-4)
  @test isapprox(res_sde_p'[2], sum(@. (Wfix)*u₀^2*exp(2*(p[1])*tarray+2*p[2]*Wfix)), rtol = 1e-4)
  @test isapprox(res_sde_p'[1], res_sde_trackerp[1], rtol = 1e-4)

  # SDE adjoint results (with noise != 0)

  Random.seed!(seed)
  prob_oop_sde2 = SDEProblem(f_oop_linear,σ_oop_linear,u₀,trange,p2)
  sol_oop_sde2 = solve(prob_oop_sde2,RKMil(interpretation=:Stratonovich),dt=tend/1e6,adaptive=false,save_noise=true)


  res_sde_u02, res_sde_p2 = adjoint_sensitivities(sol_oop_sde2,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint())

  @info res_sde_p2

  # test consitency for different switches for the noise Jacobian
  res_sde_u02a, res_sde_p2a = adjoint_sensitivities(sol_oop_sde2,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint(noise=false))

  @test isapprox(res_sde_u02, res_sde_u02a, rtol = 1e-6)
  @test isapprox(res_sde_p2, res_sde_p2a, rtol = 1e-6)

  @info res_sde_p2a

  res_sde_u02a, res_sde_p2a = adjoint_sensitivities(sol_oop_sde2,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint(noise=DiffEqSensitivity.ZygoteNoise()))

  @test isapprox(res_sde_u02, res_sde_u02a, rtol = 1e-6)
  @test isapprox(res_sde_p2, res_sde_p2a, rtol = 1e-6)

  @info res_sde_p2a

  res_sde_u02a, res_sde_p2a = adjoint_sensitivities(sol_oop_sde2,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint(noise=DiffEqSensitivity.ReverseDiffNoise()))

  @test isapprox(res_sde_u02, res_sde_u02a, rtol = 1e-6)
  @test isapprox(res_sde_p2, res_sde_p2a, rtol = 1e-6)

  @info res_sde_p2a

  function GSDE2(p)
    Random.seed!(seed)
    tmp_prob = remake(prob_oop_sde2,u0=eltype(p).(prob_oop_sde2.u0),p=p,
                      tspan=eltype(p).(prob_oop_sde2.tspan)
                      #,abstol=abstol, reltol=reltol
                      )
    sol = solve(tmp_prob,RKMil(interpretation=:Stratonovich),dt=tend/1e6,adaptive=false,sensealg=DiffEqBase.SensitivityADPassThrough(),saveat=Array(t))
    A = convert(Array,sol)
    res = g(A,p,nothing)
  end
  res_sde_forward2 = ForwardDiff.gradient(GSDE2,p2)
  res_sde_reverse2 = ReverseDiff.gradient(GSDE2,p2)


  Random.seed!(seed)
  res_sde_trackeru02, res_sde_trackerp2 = Zygote.gradient((u0,p)->sum(solve(prob_oop_sde2,RKMil(interpretation=:Stratonovich),dt=tend/1e3,adaptive=false,u0=u0,p=p,saveat=Array(t),sensealg=TrackerAdjoint()).^2.0/2.0),u₀,p2)


  Wfix = [sol_oop_sde2.W(t)[1][1] for t in tarray]
  resp1 = sum(@. tarray*u₀^2*exp(2*(p2[1])*tarray+2*p2[2]*Wfix))
  resp2 = sum(@. (Wfix)*u₀^2*exp(2*(p2[1])*tarray+2*p2[2]*Wfix))
  resp = [resp1, resp2]

  @test isapprox(res_sde_forward2, resp, rtol = 2e-6)
  @test isapprox(res_sde_reverse2, resp, rtol = 2e-6)
  @test isapprox(res_sde_trackerp2, resp, rtol = 4e-1)

  @test isapprox(res_sde_p2', res_sde_forward2, rtol = 1e-6)
  @test isapprox(res_sde_p2', resp, rtol = 2e-6)

  @info "ForwardDiff" res_sde_forward2
  @info "ReverseDiff" res_sde_reverse2
  @info "Exact" resp
  @info "Adjoint SDE" res_sde_p2


  # consistency check with respect to tracker
  Random.seed!(seed)
  prob_oop_sde2 = SDEProblem(f_oop_linear,σ_oop_linear,u₀,trange,p2)
  sol_oop_sde2 = solve(prob_oop_sde2,RKMil(interpretation=:Stratonovich),dt=tend/1e3,adaptive=false,save_noise=true)
  res_sde_u02, res_sde_p2 = adjoint_sensitivities(sol_oop_sde2,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e3,adaptive=false,sensealg=BacksolveAdjoint())

  @test isapprox(res_sde_p2', res_sde_trackerp2, rtol = 3e-4)

  # Free memory to help Travis

  Wfix = nothing
  res_sde_forward2 = nothing
  res_sde_reverse2 = nothing
  resp = nothing
  res_sde_trackerp2 = nothing
  res_sde_u02 = nothing
  sol_oop_sde2 = nothing
  res_sde_u02a = nothing
  res_sde_p2a = nothing
  res_sde_p2 = nothing
  sol_oop_sde = nothing
  GC.gc()

  # SDE adjoint results with diagonal noise

  Random.seed!(seed)
  prob_oop_sde2 = SDEProblem(f_oop_linear,σ_oop_linear,[u₀;u₀;u₀],trange,p2)
  sol_oop_sde2 = solve(prob_oop_sde2,EulerHeun(),dt=tend/1e6,adaptive=false,save_noise=true)

  @info "Diagonal Adjoint"

  res_sde_u02, res_sde_p2 = adjoint_sensitivities(sol_oop_sde2,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint())

  res_sde_u03, res_sde_p3 = adjoint_sensitivities(sol_oop_sde2,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint(noise=false))

  res_sde_u04, res_sde_p4 = adjoint_sensitivities(sol_oop_sde2,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint(noise=DiffEqSensitivity.ZygoteNoise()))

  res_sde_u05, res_sde_p5 = adjoint_sensitivities(sol_oop_sde2,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint(noise=DiffEqSensitivity.ReverseDiffNoise()))

  @info  res_sde_p2

  sol_oop_sde2 = nothing
  GC.gc()

  @test isapprox(res_sde_p2, res_sde_p3, rtol = 1e-7)
  @test isapprox(res_sde_p2, res_sde_p4, rtol = 1e-7)
  @test isapprox(res_sde_p2, res_sde_p5, rtol = 1e-7)

  @test isapprox(res_sde_u02, res_sde_u03, rtol = 1e-7)
  @test isapprox(res_sde_u02, res_sde_u04, rtol = 1e-7)
  @test isapprox(res_sde_u02, res_sde_u05, rtol = 1e-7)

  @info "Diagonal ForwardDiff"
  res_sde_forward2 = ForwardDiff.gradient(GSDE2,p2)
  #@info "Diagonal ReverseDiff"
  #res_sde_reverse2 = ReverseDiff.gradient(GSDE2,p2)

  #@test isapprox(res_sde_forward2, res_sde_reverse2, rtol = 1e-6)
  @test isapprox(res_sde_p2', res_sde_forward2, rtol = 1e-3)
  #@test isapprox(res_sde_p2', res_sde_reverse2, rtol = 1e-3)

  # u0
  function GSDE3(u)
    Random.seed!(seed)
    tmp_prob = remake(prob_oop_sde2,u0=u,p=eltype(p).(prob_oop_sde2.p),
                      tspan=eltype(p).(prob_oop_sde2.tspan)
                      #,abstol=abstol, reltol=reltol
                      )
    sol = solve(tmp_prob,RKMil(interpretation=:Stratonovich),dt=tend/1e6,adaptive=false,saveat=Array(t))
    A = convert(Array,sol)
    res = g(A,p,nothing)
  end

  @info "ForwardDiff u0"
  res_sde_forward2 = ForwardDiff.gradient(GSDE3,[u₀;u₀;u₀])

  @test isapprox(res_sde_u02, res_sde_forward2, rtol = 1e-4)

end

##
## Inplace
##
@testset "SDE inplace Tests" begin
  f!(du,u,p,t) = du.=p[1]*u
  σ!(du,u,p,t) = du.=p[2]*u

  Random.seed!(seed)
  prob_sde = SDEProblem(f!,σ!,u₀,trange,p2)
  sol_sde = solve(prob_sde,RKMil(interpretation=:Stratonovich),dt=tend/1e6,adaptive=false, save_noise=true)


  # Wfix = [sol_sde.W(t)[1][1] for t in tarray]
  # resp1 = sum(@. tarray*u₀^2*exp(2*(p2[1])*tarray+2*p2[2]*Wfix))
  # resp2 = sum(@. (Wfix)*u₀^2*exp(2*(p2[1])*tarray+2*p2[2]*Wfix))
  # resp = [resp1, resp2]
  # resu0 = sum(@. u₀*exp(2*(p2[1])*tarray+2*p2[2]*Wfix))

  function GSDE(p)
    Random.seed!(seed)
    tmp_prob = remake(prob_sde,u0=eltype(p).(prob_sde.u0),p=p,
                      tspan=eltype(p).(prob_sde.tspan))
    sol = solve(tmp_prob,RKMil(interpretation=:Stratonovich),dt=tend/1e6,adaptive=false,saveat=Array(t))
    A = convert(Array,sol)
    res = g(A,p,nothing)
  end

  res_sde_forward = ForwardDiff.gradient(GSDE,p2)


  res_sde_u0, res_sde_p = adjoint_sensitivities(sol_sde,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint())

  @test isapprox(res_sde_p', res_sde_forward, rtol = 1e-5)

  @info res_sde_p

  res_sde_u02, res_sde_p2 = adjoint_sensitivities(sol_sde,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint(noise=false))

  @info res_sde_p2

  @test isapprox(res_sde_p, res_sde_p2, rtol = 1e-5)
  @test isapprox(res_sde_u0, res_sde_u02, rtol = 1e-5)

  res_sde_u02, res_sde_p2 = adjoint_sensitivities(sol_sde,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint(noise=DiffEqSensitivity.ZygoteNoise()))

  @info res_sde_p2

  @test isapprox(res_sde_p, res_sde_p2, rtol = 1e-5) # not broken here because it just uses the vjps
  @test isapprox(res_sde_u0 ,res_sde_u02, rtol = 1e-5)

  res_sde_u02, res_sde_p2 = adjoint_sensitivities(sol_sde,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint(noise=DiffEqSensitivity.ReverseDiffNoise()))

  @info res_sde_p2

  @test isapprox(res_sde_p, res_sde_p2, rtol = 1e-10)
  @test isapprox(res_sde_u0 ,res_sde_u02, rtol = 1e-10)


  # diagonal noise

  #compare with oop version
  f_oop_linear(u,p,t) = p[1]*u
  σ_oop_linear(u,p,t) = p[2]*u
  Random.seed!(seed)
  prob_oop_sde = SDEProblem(f_oop_linear,σ_oop_linear,[u₀;u₀;u₀],trange,p2)
  sol_oop_sde = solve(prob_oop_sde,EulerHeun(),dt=tend/1e6,adaptive=false,save_noise=true)
  res_oop_u0, res_oop_p = adjoint_sensitivities(sol_oop_sde,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint())

  @info res_oop_p

  Random.seed!(seed)
  prob_sde = SDEProblem(f!,σ!,[u₀;u₀;u₀],trange,p2)
  sol_sde = solve(prob_sde,EulerHeun(),dt=tend/1e6,adaptive=false,save_noise=true)

  res_sde_u0, res_sde_p = adjoint_sensitivities(sol_sde,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint())

  @test isapprox(res_sde_p, res_oop_p, rtol = 1e-6)
  @test isapprox(res_sde_u0 ,res_oop_u0, rtol = 1e-6)

  @info res_sde_p

  res_sde_u0, res_sde_p = adjoint_sensitivities(sol_sde,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint(noise=false))

  @test isapprox(res_sde_p, res_oop_p, rtol = 1e-6)
  @test isapprox(res_sde_u0 ,res_oop_u0, rtol = 1e-6)

  @info res_sde_p

  res_sde_u0, res_sde_p = adjoint_sensitivities(sol_sde,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint(noise=DiffEqSensitivity.ZygoteNoise()))

  @test_broken isapprox(res_sde_p, res_oop_p, rtol = 1e-6)
  @test isapprox(res_sde_u0 ,res_oop_u0, rtol = 1e-6)

  @info res_sde_p

  res_sde_u0, res_sde_p = adjoint_sensitivities(sol_sde,EulerHeun(),dg!,Array(t)
      ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint(noise=DiffEqSensitivity.ReverseDiffNoise()))

  @test isapprox(res_sde_p, res_oop_p, rtol = 1e-6)
  @test isapprox(res_sde_u0 ,res_oop_u0, rtol = 1e-6)

  @info res_sde_p
end


# scalar noise
@testset "SDE scalar noise tests" begin
  using DiffEqNoiseProcess

  f!(du,u,p,t) = (du .= p[1]*u)
  σ!(du,u,p,t) = (du .= p[2]*u)

  @info "scalar SDE"

  Random.seed!(seed)
  W = WienerProcess(0.0,0.0,0.0)
  u0 = rand(2)

  linear_analytic_strat(u0,p,t,W) = @.(u0*exp(p[1]*t+p[2]*W))

  prob = SDEProblem(SDEFunction(f!,σ!,analytic=linear_analytic_strat),σ!,u0,trange,p2,
    noise=W
    )
  sol = solve(prob,EulerHeun(), dt=tend/1e6, save_noise=true)

  @test isapprox(sol.u_analytic,sol.u, atol=2e-5)

  res_sde_u0, res_sde_p = adjoint_sensitivities(sol,EulerHeun(),dg!,Array(t)
    ,dt=tend/1e6,adaptive=false,sensealg=BacksolveAdjoint())

  function compute_grads(sol, scale=1.0)
    xdis = sol(tarray)
    helpu1 = [u[1] for u in xdis.u]
    tmp1 = sum((@. xdis.t*helpu1*helpu1))

    Wtmp = [sol.W(t)[1][1] for t in tarray]
    tmp2 = sum((@. Wtmp*helpu1*helpu1))

    tmp3 = sum((@. helpu1*helpu1))/helpu1[1]

    return [tmp3, scale*tmp3], [tmp1*(1.0+scale^2), tmp2*(1.0+scale^2)]
  end

  @test isapprox(compute_grads(sol, u0[2]/u0[1])[2], res_sde_p', atol=1e-6)
  @test isapprox(compute_grads(sol, u0[2]/u0[1])[1], res_sde_u0, atol=1e-6)
end
