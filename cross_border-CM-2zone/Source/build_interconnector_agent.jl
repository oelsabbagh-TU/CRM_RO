function build_interconnector_agent!(mod::Model)

    # ─────────────────────────────────────────────────────────────────────────
    # 2-zone variant
    #
    # For a two-zone system with no loop flows (radial topology), PTDF-based
    # constraints collapse to a single bilateral line-capacity limit on the
    # cross-border net exchange.  We therefore drop the DC power-flow mapping
    # and thermal constraints and replace them with a simple |g[jz]| ≤ Fmax_border
    # constraint, where Fmax_border is the sum of thermal limits of all lines
    # connecting different zones.  The zonal net-position definition (net_pos)
    # and the nodal-injection balance (sys_balance) are retained unchanged.
    # ─────────────────────────────────────────────────────────────────────────

    # Sets
    JH = mod.ext[:sets][:JH]           # hours
    JZ = mod.ext[:sets][:JZ]           # zones
    JL = mod.ext[:sets][:JL]           # lines
    JN = mod.ext[:sets][:JN]           # nodes

    # Parameters
    W = mod.ext[:parameters][:weight]                            # hour weights
    λ_all = mod.ext[:parameters][:λ_all]                         # |H|×|Z| EOM prices per zone

    # retrieved from ADMM_subroutine
    D_nodal = mod.ext[:parameters][:D_nodal]                # |H|×|N|
    Y_nodal = mod.ext[:parameters][:Y_nodal]                # |H|×|N|
    Y_zonal = mod.ext[:parameters][:Y_zonal]                # |Z| zonal capacity allocation
    g_bar_all = mod.ext[:parameters][:g_bar_all]            # |H|×|Z|
    ρ_all = mod.ext[:parameters][:ρ_all]                    # |Z|
    BRANCHES = mod.ext[:parameters][:BRANCHES]              # lines [(from,to,Fmax)]
    zone_of_idx = mod.ext[:parameters][:zone_of_idx]
    zone_of_node = mod.ext[:parameters][:zone_of_node]      # Dict{Symbol,Symbol}
    rc = mod.ext[:parameters][:reserve_cost]

    # Identify cross-border lines (from-zone ≠ to-zone) and sum their thermal
    # capacities to get the total allowed cross-border exchange.
    border_lines = [jl for jl in JL if zone_of_node[BRANCHES[jl][1]] != zone_of_node[BRANCHES[jl][2]]]
    Fmax_border = isempty(border_lines) ? 0.0 : sum(BRANCHES[jl][3] for jl in border_lines)
    mod.ext[:parameters][:border_Fmax] = Fmax_border
    mod.ext[:parameters][:border_lines] = border_lines

    # Variables
    g = mod.ext[:variables][:g] = @variable(mod, g[jh=JH,jz=JZ], base_name = "netposition")                     # net position: positive => import
    r = mod.ext[:variables][:r] = @variable(mod, r[jh in JH, jn in JN], base_name = "nodal_injection")          # nodal injections

    g_bar = mod.ext[:variables][:g_bar] = @variable(mod, [jh=JH, jn=JN], lower_bound=0, base_name="nodal_generation")          # nodal generation
    y_bar = mod.ext[:variables][:y_bar] = @variable(mod, [jn=JN], lower_bound=0, base_name="nodal_capacity")    # nodal capacity allocation
    s = mod.ext[:variables][:s] = @variable(mod, [jn in JN], lower_bound = 0, base_name = "network_reserve")    # reserve provision to ensure feasibility

    # Objective
    mod.ext[:objective] = @objective(mod, Min,
    - sum(W[jh,jz] * λ_all[jh,jz] * g[jh,jz] for jh in JH, jz in JZ)
    + sum(W[jh,jz] * (ρ_all[jz]/2) * (g[jh,jz] - g_bar_all[jh,jz])^2 for jh in JH, jz in JZ)
    + sum(rc * s[jn] for jn in JN)
    )

    # -------------------------------------------------------------
    # Constraints --> simple bilateral line-capacity limit
    # -------------------------------------------------------------

    # nodal balance constraint: nodal injection = generation - demand
    mod.ext[:constraints][:nodal_balance] = @constraint(mod, [jh in JH, jn in JN],
        r[jh, jn] == g_bar[jh, jn] - D_nodal[jh,jn])

    # nodal capacity limit
    mod.ext[:constraints][:cap_limit] = @constraint(mod, [jh in JH, jn in JN], (g_bar[jh, jn] - Y_nodal[jh, jn]) <= y_bar[jn] + s[jn])

    # zonal capacity allocation to nodes
    mod.ext[:constraints][:capacity_allocation] = @constraint(mod, [jz in JZ], Y_zonal[jz] == sum(y_bar[jn] for jn in JN if zone_of_idx[jn] == jz))

    # Aggregate nodal flows to zonal net positions (import-positive convention)
    mod.ext[:constraints][:net_pos] = @constraint(mod, [jh in JH, jz in JZ],
        g[jh, jz] == - sum(r[jh, jn] for jn in JN if zone_of_idx[jn] == jz)
    )

    # System balance (sum injections = 0)
    mod.ext[:constraints][:sys_balance] = @constraint(mod, [jh in JH],
        sum(r[jh, jn] for jn in JN) == 0
    )

    # Cross-border line-capacity limit.
    # With system balance, g[A] = -g[B] in 2-zone, so constraining each zone's
    # net position to ±Fmax_border is equivalent and robust to any zone ordering.
    mod.ext[:constraints][:border_limit] = @constraint(mod, [jh in JH, jz in JZ],
        -Fmax_border <= g[jh, jz] <= Fmax_border
    )

    return mod
end
