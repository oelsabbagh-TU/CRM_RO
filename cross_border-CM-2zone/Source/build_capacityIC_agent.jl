function build_capacityIC_agent!(mod::Model)
    # ─────────────────────────────────────────────────────────────────────────
    # 2-zone variant
    #
    # PTDF/FB branch removed: for a radial two-zone system FBMC collapses to
    # an NTC-style bilateral exchange with a single line-capacity limit, so we
    # keep only the simplified bilateral formulation using TCONNECT / ATC from
    # the config, and drop the FB branch entirely.
    # ─────────────────────────────────────────────────────────────────────────

    # Sets
    JZ = mod.ext[:sets][:JZ]           # zones
    JN = mod.ext[:sets][:JN]           # nodes
    JS = mod.ext[:sets][:JS]           # scarcity scenarios

    # Parameters
    zone_of_idx = mod.ext[:parameters][:zone_of_idx]
    zone_syms = mod.ext[:parameters][:zone_syms]
    node_syms = mod.ext[:parameters][:nodes]
    zone_idx = Dict(z => i for (i, z) in enumerate(zone_syms))
    scarcity_matrix = mod.ext[:parameters][:scarcity_matrix]
    CapCM_zonal = mod.ext[:parameters][:CapCM_zonal]
    Cap_Demand_nodal = mod.ext[:parameters][:Cap_Demand_nodal]
    rc = mod.ext[:parameters][:reserve_cost]

    zone_of_node = mod.ext[:parameters][:zone_of_node]

    # ADMM penalty parameters for capacity market
    cap_bar = mod.ext[:parameters][:cap_bar]
    λ_CM = mod.ext[:parameters][:λ_CM]
    ρ_CM = mod.ext[:parameters][:ρ_CM]

    y_bar_nodal = mod.ext[:parameters][:y_bar_nodal]

    # Bilateral exchange parameters (set by define_capacityIC_parameters!)
    TCONNECT = mod.ext[:parameters][:TCONNECT]
    ATC = mod.ext[:parameters][:ATC]

    # Variables
    cap_cm = mod.ext[:variables][:cap_cm] = @variable(mod, [jz=JZ], base_name = "netposition")                      # net position: positive => import
    s_cm = mod.ext[:variables][:s_cm] = @variable(mod, [jn in JN], lower_bound = 0, base_name = "network_reserve")  # reserve provision to ensure feasibility
    CapCM_nodal = mod.ext[:variables][:CapCM_nodal] = @variable(mod, [jn=JN], lower_bound=0, base_name="nodal_capacity") # nodal capacity allocation
    g_scar = mod.ext[:variables][:g_scar] = @variable(mod, [js=JS, jn=JN], lower_bound=0, base_name="nodal_generation") # nodal generation under scarcity
    ex_cm = mod.ext[:variables][:ex_cm] = @variable(mod, [t in TCONNECT], base_name="ex_cm")                        # bilateral exchange on connection t = (from_zone,to_zone)

    # Expressions
    demand = mod.ext[:expressions][:demand] = @expression(mod, [js in JS, jn in JN],
        scarcity_matrix[js, zone_idx[zone_of_node[node_syms[jn]]]] * Cap_Demand_nodal[jn])

    # Objective function
    mod.ext[:objective] = @objective(mod, Min,
        - sum(λ_CM[jz] * cap_cm[jz] for jz in JZ)
        + sum(ρ_CM[jz]/2 * (cap_cm[jz] - cap_bar[jz])^2 for jz in JZ)
        + sum(rc * s_cm[jn] for jn in JN)
        )

    # -------------------------------------------------------------
    # Constraints
    # -------------------------------------------------------------

    # g_scar ≤ CapCM_nodal + s_res
    mod.ext[:constraints][:cap_limit] =
        @constraint(mod, [js in JS, jn in JN], g_scar[js, jn] <= CapCM_nodal[jn] + s_cm[jn])

    # CapCM_nodal ≤ y_bar_nodal
    mod.ext[:constraints][:capcm_limit] = @constraint(mod, [jn in JN], CapCM_nodal[jn] <= y_bar_nodal[jn])

    # zonal capacity allocation to nodes
    mod.ext[:constraints][:capacity_allocation] = @constraint(mod, [jz in JZ],
        sum(CapCM_nodal[jn] for jn in JN if zone_of_idx[jn] == jz) == CapCM_zonal[jz])

    # Overall net position sums to zero (CM imports and exports balance)
    mod.ext[:constraints][:global_bal] =
        @constraint(mod, sum(cap_cm[jz] for jz in JZ) == 0)

    # Zonal balance under scarcity: imports cover any shortfall between scarcity
    # demand and available generation within the zone.
    mod.ext[:constraints][:zonal_balance] =
        @constraint(mod, [js in JS, jz in JZ],
            cap_cm[jz] >= -(sum(g_scar[js, jn]  for jn in JN if zone_of_idx[jn] == jz) -
                            sum(demand[js, jn]  for jn in JN if zone_of_idx[jn] == jz)))

    # Net positions derived from bilateral exchanges on each TCONNECT pair
    mod.ext[:constraints][:cap_cm_netposition] =
        @constraint(mod, [js in JS, jz in JZ],
            cap_cm[jz] ==
                sum(ex_cm[t] for t in TCONNECT if t[2] == zone_syms[jz]) -
                sum(ex_cm[t] for t in TCONNECT if t[1] == zone_syms[jz])
        )

    # ATC limits on each directed exchange pair
    mod.ext[:constraints][:cap_cm_atc_limit] =
        @constraint(mod, [t in TCONNECT], ATC[t][2] <= ex_cm[t] <= ATC[t][1])

    return mod
end
