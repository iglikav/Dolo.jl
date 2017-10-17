include("ITI_additional.jl")

"""
Computes a global solution for a model via backward Improved Time Iteration. The algorithm is applied to the residuals of the arbitrage equations. The idea is to solve the system G(x) = 0 as a big nonlinear system in x, where the inverted Jacobian matrix is approximated by an infinite sum (Neumann series).

If the initial guess for the decision rule is not explicitly provided, the initial guess is provided by `ConstantDecisionRule`.
If the stochastic process for the model is not explicitly provided, the process is taken from the default provided by the model object, `model.exogenous`

# Arguments
* `model::NumericModel`: Model object that describes the current model environment.
* `dprocess`: The stochastic process associated with the exogenous variables in the model.
* `init_dr`: Initial guess for the decision rule.
* `maxbsteps` Maximum number of backsteps.
* `verbose` Set "true" if you would like to see the details of the infinite sum convergence.
* `smaxit` Maximum number of iterations to compute the Neumann series.
* `complementarities`
* `compute_radius`
* `trace` Record Iteration informations
# Returns
* `sol`: Improved Time Iteration results
"""

function improved_time_iteration(model::AbstractModel, dprocess::AbstractDiscretizedProcess,
                                 init_dr::AbstractDecisionRule, grid;
                                 maxbsteps::Int=10, verbose::Bool=true, verbose_jac::Bool=false,
                                 tol::Float64=1e-8, smaxit::Int=500, maxit::Int=1000,
                                 complementarities::Bool=true, compute_radius::Bool=false, trace::Bool=false)


   parms = model.calibration[:parameters]

   n_m = max(n_nodes(dprocess), 1) # number of exo states today
   n_mt = n_inodes(dprocess,1)  # number of exo states tomorrow
   n_s = length(model.symbols[:states]) # number of endo states

   s = nodes(grid)
   N_s = size(s,1)
   n_x = size(model.calibration[:controls],1)

   x0 = [init_dr(i, s) for i=1:n_m]
   ddr=CachedDecisionRule(dprocess, grid, x0)
   ddr_filt = CachedDecisionRule(dprocess, grid, x0)
   set_values!(ddr,x0)

   steps = 0.5.^collect(0:maxbsteps)

   if complementarities == true
     x_lb = Array{Float64,2}[cat(1, [controls_lb(model, node(dprocess, i), s[n, :], parms)' for n=1:N_s]...) for i=1:n_m]
     x_ub = Array{Float64,2}[cat(1, [controls_ub(model, node(dprocess, i), s[n, :], parms)' for n=1:N_s]...) for i=1:n_m]
   end

   trace_data = []

   x=x0

  #  ## memory allocation
  #  jres = zeros(n_m,n_mt,N_s,n_x,n_x)
  #  S_ij = zeros(n_m,n_mt,N_s,n_s)

   ######### Loop     for it in range(maxit):
   it=0
   it_invert=0
   
   s_ = to_LOP(s)
   x_ = [to_LOP(el) for el in x]
   p_ = SVector(parms...)

   res, dres = euler_residuals_2(model,s_,x_,ddr,dprocess,p_)

   return res, dres

   res_init = euler_residuals(model,s_,x_,ddr,dprocess,p_,with_jres=false)
   res_init,J_ij,S_ij = euler_residuals(model,s_,x_,ddr,dprocess,p_,with_jres=true) #,set_dr=false) #,jres=jres,S_ij=S_ij)

   err_0 = absmax(res_init)
   println(err_0)
   return res_init

   err_0 = abs(maximum(res_init))
   err_2= err_0
   lam0=0.0

   verbose && println(repeat("-", 120))
   verbose && println("N\tf_x\t\td_x\tTime_residuals\tTime_inversion\tTime_search\tLambda_0\tN_invert\tN_search\t")
   verbose && println(repeat("-", 120))


   if compute_radius == true
     res=zeros(res_init)
     dres = zeros(N_s*n_m, n_x, n_x)
   end

   while it <= maxit && err_0>tol
      it += 1

      jres = zeros(n_m,n_mt,N_s,n_x,n_x)
      S_ij = zeros(n_m,n_mt,N_s,n_s)

      t1 = time();

      # compute derivatives and residuals:
      # res: residuals
      # dres: derivatives w.r.t. x
      # jres: derivatives w.r.t. ~x
      # fut_S: future states

      set_values!(ddr,x)

      ff = SerialDifferentiableFunction(u-> euler_residuals(model, s, u,ddr,dprocess,parms;
                                        with_jres=false,set_dr=false))

      res, dres = ff(x)

      dres = reshape(dres, n_m, N_s, n_x, n_x)
      junk, jres, fut_S = euler_residuals(model, s, x,ddr,dprocess,parms, with_jres=true,set_dr=false) #, jres=jres, S_ij=S_ij)

      if complementarities == true
        for i_ms in 1:n_m
           dx =  x[i_ms] - x_lb[i_ms]
           res[i_ms,:,:], dres[i_ms,:,:,:], jres[i_ms,:,:,:,:] = smooth_right(res[i_ms,:,:], dres[i_ms,:,:,:], jres[i_ms,:,:,:,:], dx)
        end

        res *= -1
        dres *= -1
        jres *= -1

        for i_ms in 1:n_m
           dx =  x_ub[i_ms] -x[i_ms]
           res[i_ms,:,:], dres[i_ms,:,:,:], jres[i_ms,:,:,:,:] = smooth_right(res[i_ms,:,:], dres[i_ms,:,:,:], jres[i_ms,:,:,:,:], dx; pos = -1.0)
        end
      end

      push!(trace_data, [copy(res)])

      err_0 = abs(maximum(res))

      jres[:,:,:,:,:] *= -1.0

      ####################
      # Invert Jacobians
      t2 = time();
      tot, it_invert, lam0, errors = invert_jac(res,dres,jres,fut_S, ddr_filt; verbose=verbose_jac, maxit = smaxit)

      t3 = time();

      i_bckstps=0
      new_err=err_0
      new_x = x
      while new_err>=err_0 && i_bckstps<length(steps)
        i_bckstps +=1
        new_x = x-destack0(tot, n_m)*steps[i_bckstps]
        new_res = euler_residuals(model, s, new_x,ddr,dprocess,parms,set_dr=true)

        if complementarities == true
          for i_ms in 1:n_m
             dx =  new_x[i_ms]-x_lb[i_ms]
             new_res[i_ms,:,:] = smooth_right(new_res[i_ms,:,:], dx)
          end
          for i_ms in 1:n_m
             dx =  x_ub[i_ms] - new_x[i_ms]
             new_res[i_ms,:,:] = smooth_right(-new_res[i_ms,:,:], dx)
          end
        end

        new_err = maximum(abs, new_res)
      end
      err_2 = maximum(abs,tot)

      t4 = time();

      x = new_x
      verbose && @printf "%-6i% -10e% -17e% -15.4f% -15.4f% -15.5f% -17.3f%-17i%-5i\n" it  err_0  err_2  t2-t1 t3-t2 t4-t3 lam0 it_invert i_bckstps

   end
   verbose && println(repeat("-", 120))
   set_values!(ddr,x)

   if compute_radius == true
       lam, lam_max, lambdas = radius_jac(res,dres,jres,S_ij,ddr_filt)
   else
       lam = NaN
   end

   converged = err_0<tol

   return ImprovedTimeIterationResult(ddr.dr, it, err_0, err_2, converged, complementarities, tol, lam0, it_invert, 5.0, lam, trace_data)

end

function improved_time_iteration(model:: AbstractModel, dprocess::AbstractDiscretizedProcess,
                                 init_dr::AbstractDecisionRule;grid=Dict(), kwargs...)
    grid = get_grid(model, options=grid)
    return improved_time_iteration(model, dprocess, init_dr, grid;  kwargs...)
end

function improved_time_iteration(model, dprocess::AbstractDiscretizedProcess; grid=Dict(), kwargs...)

    init_dr = ConstantDecisionRule(model.calibration[:controls])
    return improved_time_iteration(model, dprocess, init_dr; grid=grid, kwargs...)
end


function  improved_time_iteration(model, init_dr; grid=Dict(), kwargs...)
    dprocess = discretize( model.exogenous )
    return improved_time_iteration(model, dprocess, init_dr; grid=grid, kwargs...)
end

# function improved_time_iteration(model, maxbsteps::Int=10, verbose::Bool=false,
#                                  tol::Float64=1e-8, smaxit::Int=500, maxit::Int=1000,
#                                  complementarities::Bool=true, compute_radius::Bool=false)
#     dprocess = Dolo.discretize( model.exogenous )
#     init_dr = Dolo.ConstantDecisionRule(model.calibration[:controls])
#     return improved_time_iteration(model, dprocess, init_dr, maxbsteps, verbose,tol,
#                                    smaxit, maxit,complementarities, compute_radius)
# end

function improved_time_iteration(model; grid=Dict(), kwargs...)
    dprocess = discretize( model.exogenous )
    init_dr = ConstantDecisionRule(model.calibration[:controls])
    return improved_time_iteration(model, dprocess, init_dr; grid=grid, kwargs...)
end
