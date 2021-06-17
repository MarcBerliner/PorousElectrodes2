@views @inbounds @inline function check_simulation_stop!(model::R1, int::R2, run::R3, p::R4, bounds::R5, opts::R6) where {R1<:model_output, R2<:Sundials.IDAIntegrator, method<:AbstractMethod, R3<:AbstractRun{method},R4<:param,R5<:boundary_stop_conditions,R6<:options_model}
    Y = int.u.v
    t = int.t
    tf = run.tf
    
    if t ≥ tf
        run.info.flag = 0
        run.info.exit_reason = "Final time reached"
    end

    # continue checking the bounds or return after only evaluating the time
    !opts.check_bounds && (return nothing)
    
    V = model.V[end]
    I = model.I[end]
    if !(method === run_voltage)
        if V ≤ bounds.V_min && I < 0
            run.info.flag = 1
            run.info.exit_reason = "Below minimum voltage limit"

            bounds.t_final_interp_frac = min((bounds.V_prev - bounds.V_min)/(bounds.V_prev - V), bounds.t_final_interp_frac)

            return nothing
        end
        if V ≥ bounds.V_max && I > 0
            run.info.flag = 2
            run.info.exit_reason = "Above maximum voltage limit"

            bounds.t_final_interp_frac = min((bounds.V_prev - bounds.V_max)/(bounds.V_prev - V), bounds.t_final_interp_frac)

            return nothing
        end
    end
    
    SOC = model.SOC[end]
    if SOC < bounds.SOC_min && I < 0
        run.info.flag = 3
        run.info.exit_reason = "Below minimum SOC limit"
        
        bounds.t_final_interp_frac = min((bounds.SOC_prev - bounds.SOC_min)/(bounds.SOC_prev - SOC), bounds.t_final_interp_frac)
        
        return nothing
    end
    if SOC > bounds.SOC_max && I > 0
        run.info.flag = 4
        run.info.exit_reason = "Above maximum SOC limit"
        
        bounds.t_final_interp_frac = min((bounds.SOC_prev - bounds.SOC_max)/(bounds.SOC_prev - SOC), bounds.t_final_interp_frac)
        
        return nothing
    end
    
    if p.numerics.temperature && (T = maximum(model.T[end])) > bounds.T_max
        run.info.flag = 5
        run.info.exit_reason = "Above maximum permitted temperature"
        
        bounds.t_final_interp_frac = min((bounds.T_prev - bounds.T_max)/(bounds.T_prev - T), bounds.t_final_interp_frac)
        
        return nothing
    else
        T = -1.0
    end
    
    c_s_avg = model.c_s_avg[end]
    if !isnan(bounds.c_s_n_max) && I > 0

        if p.numerics.solid_diffusion === :Fickian
            c_s_n_max = maximum(c_s_avg[(p.N.p)*(p.N.r_p)+1:end])
        else
            c_s_n_max = maximum(c_s_avg[(p.N.p)+1:end])
        end
        
        if c_s_n_max > bounds.c_s_n_max*(p.θ[:c_max_n]::Float64*p.θ[:θ_max_n]::Float64)
            run.info.flag = 6
            run.info.exit_reason = "Above c_s_n saturation threshold"
        
            bounds.t_final_interp_frac = min((bounds.c_s_n_prev - bounds.c_s_n_max*(p.θ[:c_max_n]::Float64*p.θ[:θ_max_n]::Float64))/(bounds.c_s_n_prev - c_s_n_max), bounds.t_final_interp_frac)
            
            return nothing
        end
    else
        c_s_n_max = -1.0
    end

    if (!(method === run_current) && R3 === run_constant) && I > bounds.I_max
        run.info.flag = 7
        run.info.exit_reason = "Above maximum permitted C-rate"
        
        bounds.t_final_interp_frac = min((bounds.I_prev - bounds.I_max)/(bounds.I_prev - I), bounds.t_final_interp_frac)

        return nothing
    end
    if (!(method === run_current) && R3 === run_constant) && I < bounds.I_min
        run.info.flag = 8
        run.info.exit_reason = "Below minimum permitted C-rate"
        
        bounds.t_final_interp_frac = min((bounds.I_prev - bounds.I_min)/(bounds.I_prev - I), bounds.t_final_interp_frac)

        return nothing
    end

    bounds.V_prev = V
    bounds.I_prev = I
    bounds.SOC_prev = SOC
    bounds.T_prev = T
    bounds.c_s_n_prev = c_s_n_max

    return nothing
end

function get_corrected_methods(methods)
    """
    Corrects the input methods to `Params`
    """
    if methods isa Symbol
        methods = (methods,)
    elseif isempty(methods)
        error("methods cannot be empty")
    end
    check_appropriate_method.(methods)
    
    return methods
end

@inline function get_method(I::current, V::voltage, P::power) where {
    current<:Union{Number,Symbol,Nothing,Function},
    voltage<:Union{Number,Symbol,Nothing},
    power  <:Union{Number,Symbol,Nothing,Function},
    }

    if !( sum(!(method === Nothing) for method in (current,voltage,power)) === 1 )
        error("Cannot select more than one input")
    end

    if     !isnothing(I)
        method, value = run_current(), I
    elseif !isnothing(V)
        method, value = run_voltage(), V
    elseif !isnothing(P)
        method, value = run_power(), P
    else
        error("Method not supported")
    end
    return method_and_value(method, value)
end

check_appropriate_method(method::Symbol) = @assert method ∈ (:I, :P, :V)

@inline function instant_hit_bounds(model::model_output, opts::options_model)
    var_keep = opts.var_keep
    
    fields = fieldnames(model_output)
    types = fieldtypes(model_output)
    @inbounds for (field,_type) in zip(fields,types)
        if _type <: AbstractArray{Float64} && getproperty(var_keep, field)
            x = getproperty(model, field)
            if length(x) > 1
                deleteat!(x, length(x))
            end
        end
    end
end

@inline function check_solve(run::run_constant, model::R1, int::R2, p::R3, bounds::R4, opts::R5, container::R6, keep_Y::Bool, iter::Int64, Y::Vector{Float64}, t::Float64) where {R1<:model_output, R2<:Sundials.IDAIntegrator,R3<:param,R4<:boundary_stop_conditions,R5<:options_model, R6<:run_container}
    if t === int.tprev
        error("Model failed to converge at t = $(t)")
    elseif iter === opts.maxiters
        error("Reached max iterations of $(opts.maxiters) at t = $(t)")
    elseif within_bounds(run)
        # update Y only after checking the stop conditions. this is done to store a copy of the
        # previous model run in case any back-interpolation is needed
        set_var!(model.Y, keep_Y, keep_Y ? copy(Y) : Y)

        return true
    else # no errors and run.info.flag ≠ -1
        return false
    end
end

@inline function check_solve(run::run_function, model::R1, int::R2, p::R3, bounds::R4, opts::R5, container::R6, keep_Y::Bool, iter::Int64, Y::Vector{Float64}, t::Float64) where {R1<:model_output, R2<:Sundials.IDAIntegrator,R3<:param,R4<:boundary_stop_conditions,R5<:options_model, R6<:run_container}
    if iter === opts.maxiters
        error("Reached max iterations of $(opts.maxiters) at t = $(int.t)")
    elseif within_bounds(run)
        # update Y only after checking the stop conditions. this is done to store a copy of the
        # previous model run in case any back-interpolation is needed
        set_var!(model.Y, keep_Y, keep_Y ? copy(Y) : Y)
        
        # check to see if the run needs to be reinitialized
        if t - int.tprev < 1e-3opts.reltol
            check_reinitialization!(model, int, run, p, bounds, opts, container)
        end

        return true
    else # no errors and run.info.flag ≠ -1
        return false
    end
end

@inline function check_reinitialization!(model::R1, int::R2, run::R3, p::R4, bounds::R5, opts::R6, container::R7) where {R1<:model_output, R2<:Sundials.IDAIntegrator, R3<:AbstractRun,R4<:param,R5<:boundary_stop_conditions,R6<:options_model,R7<:run_container}
    """
    Checking the current function for discontinuities.
    If there is a significant change in current after a step size of dt = reltol,
    then rerun Newton's method and reinitialize at this new time step.
    """
    
    Y = int.u.v
    t_new = int.t + opts.reltol

    value_old = value(run)
    value_new = run.func(Y, p, t_new)::Float64
    
    if !≈(value_old, value_new, atol=opts.abstol, rtol=opts.reltol)
        @inbounds Y[p.ind.I] .= value_new
        YP = int.du.v
        
        initialize_states!(p, Y, YP, run, opts, container, @inbounds model.SOC[end])

        Sundials.IDAReInit(int.mem, t_new, Y, YP)
    end
    return nothing
end

@inline function check_errors_parameters_runtime(p::R1,opts::R2,tspan::R3) where {R1<:param,R2<:options_model,R3<:Union{Number,AbstractArray,Nothing}}
    ϵ_sp, ϵ_sn = active_material(p)

    if ( ϵ_sp > 1 ) error("ϵ_p + ϵ_fp must be ∈ [0, 1)") end
    if ( ϵ_sn > 1 ) error("ϵ_n + ϵ_fn must be ∈ [0, 1)") end
    if ( p.θ[:θ_max_p]::Float64 > p.θ[:θ_min_p]::Float64 ) error("θ_max_p must be < θ_min_p") end
    if ( p.θ[:θ_min_n]::Float64 > p.θ[:θ_max_n]::Float64 ) error("θ_min_n must be < θ_max_n") end
    if ( R3 === Nothing && !opts.check_bounds ) error("Must specify a tspan when `check_bounds = false`") end

    return nothing
end

function check_errors_initial(θ, numerics, N)
    if numerics.aging === :R_aging && length(θ[:ϵ_n]) === 1
        θ[:ϵ_n] = θ[:ϵ_n][1] .* ones(N.n)
    end

    if !(numerics.jacobian ∈ (:symbolic, :AD))
        error("`jacobian` can either be :symbolic or :AD")
    end

    return nothing
end