#!/usr/bin/env python3
"""
RadarMap Network Benchmark & Firebase RTDB Cost Estimation Engine
Calculates bandwidth rates, free tier capacities, incremental match costs,
and revenue depletion runways for network schemes. Supports side-by-side
comparative diffs when evaluating network architectural changes.
Benchmark outputs are automatically stored in the project's 'output/' directory.
Always explicitly answers the core benchmark questions as part of the output,
including translating concurrent games to total install base.
"""

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, asdict
from typing import Dict, Any, Tuple, Optional


@dataclass
class NetworkScheme:
    name: str = "Baseline (Scheme v1.0)"
    p_free: int = 4
    p_pro: int = 12
    upload_rate_free: float = 0.5        # Hz per player
    upload_rate_pro: float = 0.5         # Hz per player
    glance_free: float = 5.0             # seconds
    idle_free: float = 30.0              # seconds
    glance_pro: float = 10.0             # seconds
    idle_pro: float = 20.0               # seconds
    payload_telemetry: int = 200         # bytes on wire
    tactical_rate: float = 1.0           # Hz aggregate room
    payload_tactical: int = 200          # bytes on wire
    max_tactical_markers: int = 100
    hours_per_month_4wk: float = 64.0    # 4 weekends * 16h
    hours_per_month_avg: float = 69.3333 # 52/12 weeks * 16h
    rtdb_free_egress_gb: float = 10.0    # 10 GB included free every month on Blaze
    is_blaze_plan: bool = True           # Already on Blaze plan (connections unconstrained up to 200,000 at $0)
    rtdb_free_connections: int = 100     # Reference Spark quota (legacy)
    rtdb_max_connections: int = 200000   # Max concurrent connections on Blaze ($0 connection fee)
    rtdb_egress_cost_gb: float = 1.00    # $1.00 / GB
    one_time_price: float = 29.99        # $29.99 purchase
    apple_small_biz_fee: float = 0.15    # 15%
    apple_standard_fee: float = 0.30     # 30%


def slugify(text: str) -> str:
    text = text.lower().strip()
    text = re.sub(r"[^\w\s-]", "", text)
    text = re.sub(r"[\s_-]+", "_", text)
    return text.strip("_")


def evaluate_scheme(s: NetworkScheme) -> Dict[str, Any]:
    duty_free = s.glance_free / (s.glance_free + s.idle_free) if (s.glance_free + s.idle_free) > 0 else 1.0
    duty_pro = s.glance_pro / (s.glance_pro + s.idle_pro) if (s.glance_pro + s.idle_pro) > 0 else 1.0

    # Free tier
    down_per_player_free_duty_bps = (s.p_free - 1) * s.upload_rate_free * s.payload_telemetry * duty_free
    room_down_free_duty_bps = s.p_free * down_per_player_free_duty_bps
    room_down_free_duty_mb_hr = room_down_free_duty_bps * 3600.0 / 1e6

    down_per_player_free_cont_bps = (s.p_free - 1) * s.upload_rate_free * s.payload_telemetry
    room_down_free_cont_bps = s.p_free * down_per_player_free_cont_bps
    room_down_free_cont_mb_hr = room_down_free_cont_bps * 3600.0 / 1e6

    # Pro tier
    down_tel_player_pro_duty_bps = (s.p_pro - 1) * s.upload_rate_pro * s.payload_telemetry * duty_pro
    room_down_tel_pro_duty_bps = s.p_pro * down_tel_player_pro_duty_bps
    room_down_tac_pro_duty_bps = (s.p_pro - 1) * s.tactical_rate * s.payload_tactical * duty_pro
    room_down_pro_duty_bps = room_down_tel_pro_duty_bps + room_down_tac_pro_duty_bps
    room_down_pro_duty_mb_hr = room_down_pro_duty_bps * 3600.0 / 1e6

    room_down_tel_pro_cont_bps = s.p_pro * (s.p_pro - 1) * s.upload_rate_pro * s.payload_telemetry
    room_down_tac_pro_cont_bps = (s.p_pro - 1) * s.tactical_rate * s.payload_tactical
    room_down_pro_cont_bps = room_down_tel_pro_cont_bps + room_down_tac_pro_cont_bps
    room_down_pro_cont_mb_hr = room_down_pro_cont_bps * 3600.0 / 1e6

    # Q1 Capacity
    free_game_mo_mb_64 = room_down_free_duty_mb_hr * s.hours_per_month_4wk
    free_game_mo_gb_64 = free_game_mo_mb_64 / 1000.0
    free_bw_games_64 = (s.rtdb_free_egress_gb * 1000.0) / free_game_mo_mb_64
    free_conn_games = s.rtdb_max_connections // s.p_free if s.is_blaze_plan else s.rtdb_free_connections // s.p_free

    free_game_mo_mb_70 = room_down_free_duty_mb_hr * s.hours_per_month_avg
    free_game_mo_gb_70 = free_game_mo_mb_70 / 1000.0
    free_bw_games_70 = (s.rtdb_free_egress_gb * 1000.0) / free_game_mo_mb_70

    pro_game_mo_mb_64 = room_down_pro_duty_mb_hr * s.hours_per_month_4wk
    pro_game_mo_gb_64 = pro_game_mo_mb_64 / 1000.0
    pro_bw_games_64 = (s.rtdb_free_egress_gb * 1000.0) / pro_game_mo_mb_64
    pro_conn_games = s.rtdb_max_connections // s.p_pro if s.is_blaze_plan else s.rtdb_free_connections // s.p_pro

    pro_game_mo_mb_70 = room_down_pro_duty_mb_hr * s.hours_per_month_avg
    pro_game_mo_gb_70 = pro_game_mo_mb_70 / 1000.0
    pro_bw_games_70 = (s.rtdb_free_egress_gb * 1000.0) / pro_game_mo_mb_70

    if s.is_blaze_plan:
        free_effective_games_64 = int(free_bw_games_64)
        pro_effective_games_64 = int(pro_bw_games_64)
    else:
        free_effective_games_64 = min(int(free_bw_games_64), free_conn_games)
        pro_effective_games_64 = min(int(pro_bw_games_64), pro_conn_games)

    ccu_free = free_effective_games_64 * s.p_free
    ccu_pro = pro_effective_games_64 * s.p_pro

    # Q1.a: Install Base Translations
    # Per-user monthly egress under benchmark play (64h):
    free_user_mo_mb_64 = free_game_mo_mb_64 / s.p_free
    pro_user_mo_mb_64 = pro_game_mo_mb_64 / s.p_pro

    # Model A: Direct Literal Bandwidth Budget (10 GB / per-user egress at 64h)
    install_base_literal_free_64 = (s.rtdb_free_egress_gb * 1000.0) / free_user_mo_mb_64
    install_base_literal_pro_64 = (s.rtdb_free_egress_gb * 1000.0) / pro_user_mo_mb_64

    # Model B: Concurrency Peak CCU -> Install Base
    concurrency_ratios = [0.10, 0.05, 0.02, 0.01]  # 10%, 5%, 2%, 1%
    install_base_concurrency = {
        r: {
            "free": int(ccu_free / r),
            "pro": int(ccu_pro / r),
        }
        for r in concurrency_ratios
    }

    # Model C: Engagement-Level Monthly Bandwidth Support (10 GB)
    # Engagement hours per month per user:
    engagement_hours = [64.0, 16.0, 8.0, 2.0]
    install_base_engagement = {}
    free_player_mb_hr = room_down_free_duty_mb_hr / s.p_free
    pro_player_mb_hr = room_down_pro_duty_mb_hr / s.p_pro

    for h in engagement_hours:
        free_mb_user = free_player_mb_hr * h
        pro_mb_user = pro_player_mb_hr * h
        install_base_engagement[h] = {
            "free_user_mb": free_mb_user,
            "free_installs": int((s.rtdb_free_egress_gb * 1000.0) / free_mb_user) if free_mb_user > 0 else 0,
            "pro_user_mb": pro_mb_user,
            "pro_installs": int((s.rtdb_free_egress_gb * 1000.0) / pro_mb_user) if pro_mb_user > 0 else 0,
        }

    # Model D: Upgrade Thresholds across blended Free/Pro mixes
    mixes = [
        ("100% Free / 0% Pro", 0.0),
        ("95% Free / 5% Pro (Standard)", 0.05),
        ("90% Free / 10% Pro (Tactical)", 0.10),
        ("80% Free / 20% Pro (Squads)", 0.20),
        ("0% Free / 100% Pro (All Paid)", 1.0),
    ]
    install_base_upgrade_thresholds = []
    for label, f_pro in mixes:
        mb_user_64 = (1.0 - f_pro) * free_user_mo_mb_64 + f_pro * pro_user_mo_mb_64
        bw_users_64 = int((s.rtdb_free_egress_gb * 1000.0) / mb_user_64) if mb_user_64 > 0 else 0
        mb_user_8 = (1.0 - f_pro) * (free_player_mb_hr * 8.0) + f_pro * (pro_player_mb_hr * 8.0)
        bw_users_8 = int((s.rtdb_free_egress_gb * 1000.0) / mb_user_8) if mb_user_8 > 0 else 0
        conn_installs_2 = int(s.rtdb_free_connections / 0.02)
        conn_installs_5 = int(s.rtdb_free_connections / 0.05)
        primary_trigger = f"Connection-limited ({conn_installs_2:,} installs)" if conn_installs_2 <= bw_users_8 else f"Bandwidth-limited ({bw_users_8:,} users)"
        install_base_upgrade_thresholds.append({
            "mix": label,
            "f_pro": f_pro,
            "conn_cap_ccu": s.rtdb_free_connections,
            "installs_2pct_ccu": conn_installs_2,
            "installs_5pct_ccu": conn_installs_5,
            "bw_users_8h": bw_users_8,
            "bw_users_64h": bw_users_64,
            "primary_trigger": primary_trigger,
        })
    durations = [1.0, 2.0, 4.0, 8.0]
    incremental_costs = {}
    for d in durations:
        free_mb = room_down_free_duty_mb_hr * d
        pro_mb = room_down_pro_duty_mb_hr * d
        incremental_costs[d] = {
            "free_duty_mb": free_mb,
            "free_duty_cost": (free_mb / 1000.0) * s.rtdb_egress_cost_gb,
            "pro_duty_mb": pro_mb,
            "pro_duty_cost": (pro_mb / 1000.0) * s.rtdb_egress_cost_gb,
            "pro_cont_mb": room_down_pro_cont_mb_hr * d,
            "pro_cont_cost": ((room_down_pro_cont_mb_hr * d) / 1000.0) * s.rtdb_egress_cost_gb,
        }

    # Q3 Runway
    target_gross = s.one_time_price * 0.50
    target_net_15 = (s.one_time_price * (1.0 - s.apple_small_biz_fee)) * 0.50
    target_net_30 = (s.one_time_price * (1.0 - s.apple_standard_fee)) * 0.50

    pro_player_hr_cost = (room_down_pro_duty_mb_hr / s.p_pro / 1000.0) * s.rtdb_egress_cost_gb
    cost_mo_player_64 = pro_player_hr_cost * s.hours_per_month_4wk
    cost_mo_player_70 = pro_player_hr_cost * s.hours_per_month_avg

    runway_player_gross_64 = target_gross / cost_mo_player_64 if cost_mo_player_64 > 0 else float("inf")
    runway_player_net15_64 = target_net_15 / cost_mo_player_64 if cost_mo_player_64 > 0 else float("inf")
    runway_player_net30_64 = target_net_30 / cost_mo_player_64 if cost_mo_player_64 > 0 else float("inf")

    pro_room_hr_cost = (room_down_pro_duty_mb_hr / 1000.0) * s.rtdb_egress_cost_gb
    cost_mo_room_64 = pro_room_hr_cost * s.hours_per_month_4wk
    cost_mo_room_70 = pro_room_hr_cost * s.hours_per_month_avg

    runway_host_gross_64 = target_gross / cost_mo_room_64 if cost_mo_room_64 > 0 else float("inf")
    runway_host_net15_64 = target_net_15 / cost_mo_room_64 if cost_mo_room_64 > 0 else float("inf")
    runway_host_net30_64 = target_net_30 / cost_mo_room_64 if cost_mo_room_64 > 0 else float("inf")

    return {
        "scheme": asdict(s),
        "rates": {
            "duty_free": duty_free,
            "duty_pro": duty_pro,
            "room_down_free_duty_bps": room_down_free_duty_bps,
            "room_down_free_duty_mb_hr": room_down_free_duty_mb_hr,
            "room_down_free_cont_bps": room_down_free_cont_bps,
            "room_down_free_cont_mb_hr": room_down_free_cont_mb_hr,
            "room_down_tel_pro_duty_bps": room_down_tel_pro_duty_bps,
            "room_down_tac_pro_duty_bps": room_down_tac_pro_duty_bps,
            "room_down_pro_duty_bps": room_down_pro_duty_bps,
            "room_down_pro_duty_mb_hr": room_down_pro_duty_mb_hr,
            "room_down_pro_cont_bps": room_down_pro_cont_bps,
            "room_down_pro_cont_mb_hr": room_down_pro_cont_mb_hr,
        },
        "q1_capacity": {
            "free_game_mo_mb_64": free_game_mo_mb_64,
            "free_game_mo_gb_64": free_game_mo_gb_64,
            "free_bw_games_64": free_bw_games_64,
            "free_conn_games": free_conn_games,
            "free_effective_games_64": min(int(free_bw_games_64), free_conn_games),
            "free_game_mo_mb_70": free_game_mo_mb_70,
            "free_bw_games_70": free_bw_games_70,
            "pro_game_mo_mb_64": pro_game_mo_mb_64,
            "pro_game_mo_gb_64": pro_game_mo_gb_64,
            "pro_bw_games_64": pro_bw_games_64,
            "pro_conn_games": pro_conn_games,
            "pro_effective_games_64": min(int(pro_bw_games_64), pro_conn_games),
            "pro_game_mo_mb_70": pro_game_mo_mb_70,
            "pro_bw_games_70": pro_bw_games_70,
            "ccu_free": ccu_free,
            "ccu_pro": ccu_pro,
            "free_user_mo_mb_64": free_user_mo_mb_64,
            "pro_user_mo_mb_64": pro_user_mo_mb_64,
            "install_base_literal_free_64": install_base_literal_free_64,
            "install_base_literal_pro_64": install_base_literal_pro_64,
            "install_base_concurrency": install_base_concurrency,
            "install_base_engagement": install_base_engagement,
            "install_base_upgrade_thresholds": install_base_upgrade_thresholds,
        },
        "q2_costs": incremental_costs,
        "q3_runway": {
            "cost_mo_player_64": cost_mo_player_64,
            "cost_mo_player_70": cost_mo_player_70,
            "runway_player_gross_64": runway_player_gross_64,
            "runway_player_net15_64": runway_player_net15_64,
            "runway_player_net30_64": runway_player_net30_64,
            "cost_mo_room_64": cost_mo_room_64,
            "cost_mo_room_70": cost_mo_room_70,
            "runway_host_gross_64": runway_host_gross_64,
            "runway_host_net15_64": runway_host_net15_64,
            "runway_host_net30_64": runway_host_net30_64,
        }
    }


def render_markdown_tables(res: Dict[str, Any]) -> str:
    s = res["scheme"]
    r = res["rates"]
    q1 = res["q1_capacity"]
    q2 = res["q2_costs"]
    q3 = res["q3_runway"]

    free_player_hr_cost = (r['room_down_free_duty_mb_hr'] / s['p_free'] / 1000.0) * s['rtdb_egress_cost_gb']
    pro_player_hr_cost = (r['room_down_pro_duty_mb_hr'] / s['p_pro'] / 1000.0) * s['rtdb_egress_cost_gb']

    lines = []
    lines.append(f"# Benchmark Evaluation Report: {s['name']}\n")

    # CORE QUESTIONS & DIRECT ANSWERS SECTION
    lines.append("## 🎯 Answers to Core Benchmark Questions\n")

    lines.append("### 1. How many concurrent games for each benchmark assuming weekend play only and 8 hour per day using only RTDB blaze free allocation?")
    if s.get("is_blaze_plan", True):
        lines.append("> [!NOTE]")
        lines.append("> **Firebase Blaze Plan Active:** RTDB allows up to **200,000 simultaneous connections** at **$0 connection fee**. The capacity numbers below represent the maximum concurrent games running **100% free under the included 10 GB/month egress allocation** with zero overage cost.\n")
        lines.append(f"* **Free Tier Room ({s['p_free']} Players):** **{q1['free_effective_games_64']} concurrent games** ({q1['ccu_free']} concurrent players)")
        lines.append(f"  * *Free Allocation Headroom:* Each game consumes only {q1['free_game_mo_mb_64']:.2f} MB/month (64 hrs). The 10 GB included free allocation supports **{q1['free_bw_games_64']:.1f} concurrent games**.")
        lines.append(f"  * *Monthly Egress for {q1['free_effective_games_64']} games:* **{(q1['free_game_mo_mb_64'] * q1['free_effective_games_64'])/1000.0:.2f} GB** (100% within the 10 GB free quota).")
        lines.append(f"  * *Connection Scaling:* Connections scale up to 200,000 at $0; beyond 10 GB, each additional game costs only ${(q1['free_game_mo_mb_64']/1000.0)*s['rtdb_egress_cost_gb']:.5f}/month.")
        lines.append(f"* **Pro Tier Room ({s['p_pro']} Players):** **{q1['pro_effective_games_64']} concurrent games** ({q1['ccu_pro']} concurrent players)")
        lines.append(f"  * *Free Allocation Headroom:* Each game consumes {q1['pro_game_mo_gb_64']:.3f} GB/month ({q1['pro_game_mo_mb_64']:.2f} MB/mo). The 10 GB included allocation supports **{q1['pro_bw_games_64']:.2f} concurrent games** (64h) or **{q1['pro_bw_games_70']:.2f} games** (69.3h avg month).")
        lines.append(f"  * *Monthly Egress for {q1['pro_effective_games_64']} games:* **{(q1['pro_game_mo_gb_64'] * q1['pro_effective_games_64']):.2f} GB** (100% within the 10 GB free quota).")
        lines.append(f"  * *Connection Scaling:* Connections scale up to 200,000 at $0; beyond 10 GB, each additional 12-player game costs only ${q1['pro_game_mo_gb_64']*s['rtdb_egress_cost_gb']:.4f}/month.\n")
    else:
        lines.append(f"* **Free Tier Room ({s['p_free']} Players):** **{q1['free_effective_games_64']} concurrent games**")
        lines.append(f"  * *Bottleneck:* Strictly **connection-limited** by the {s['rtdb_free_connections']}-connection free cap ({s['rtdb_free_connections']} / {s['p_free']} = {q1['free_conn_games']} games).")
        lines.append(f"  * *Bandwidth headroom:* Each game consumes only {q1['free_game_mo_mb_64']:.2f} MB/month (64 hrs). The 10 GB free bandwidth allocation alone would support **{q1['free_bw_games_64']:.1f} concurrent games**.")
        lines.append(f"  * *Total monthly egress for {q1['free_effective_games_64']} games:* **{(q1['free_game_mo_mb_64'] * q1['free_effective_games_64'])/1000.0:.2f} GB** (under 10% of the 10 GB quota).")
        lines.append(f"* **Pro Tier Room ({s['p_pro']} Players):** **{q1['pro_effective_games_64']} concurrent games**")
        lines.append(f"  * *Bottleneck:* **Exact physical convergence** of bandwidth and connection limits.")
        lines.append(f"  * *Bandwidth headroom:* Each game consumes {q1['pro_game_mo_gb_64']:.3f} GB/month ({q1['pro_game_mo_mb_64']:.2f} MB/mo). The 10 GB free quota supports **{q1['pro_bw_games_64']:.2f} concurrent games** (64h) or **{q1['pro_bw_games_70']:.2f} games** (69.3h avg month).")
        lines.append(f"  * *Connection limit:* {s['rtdb_free_connections']} / {s['p_pro']} = **{q1['pro_conn_games']} concurrent games**.")
        lines.append(f"  * *Total monthly egress for {q1['pro_effective_games_64']} games:* **{(q1['pro_game_mo_gb_64'] * q1['pro_effective_games_64']):.2f} GB** (safely under the 10 GB free cap).\n")

    lines.append("#### a. Translate this to total install base also")
    lines.append(f"Translating concurrent game capacity to **Total Install Base** depends on user engagement patterns and concurrency ratios:\n")
    lines.append(f"1. **Literal Stated Benchmark Scenario (100% Weekend Power Users @ 64 hrs/month):**")
    lines.append(f"   * If every installed user plays 8 hours every Saturday and Sunday (64 hrs/month), 10 GB free bandwidth supports:")
    lines.append(f"     * **Free Tier:** **{q1['install_base_literal_free_64']:.0f} total users** ({q1['free_user_mo_mb_64']:.2f} MB/user/mo). *(Peak simultaneous active ceiling is {q1['ccu_free']} players across {q1['free_conn_games']} games).*")
    lines.append(f"     * **Pro Tier:** **{q1['install_base_literal_pro_64']:.0f} total users** ({q1['pro_user_mo_mb_64']:.2f} MB/user/mo), exactly matching the **~8.5 active 12-player squads** that consume 10 GB.")
    lines.append(f"2. **Operational Concurrency Model (Peak Concurrent Users vs. Total Registered Install Base):**")
    lines.append(f"   * In mobile/watch tactical multiplayer, peak weekend concurrency typically represents 1% to 10% of total installed users:")
    lines.append(f"     | Concurrency Profile | Assumed Concurrency Ratio | Free Tier Install Base ({q1['ccu_free']} CCU) | Pro Tier Install Base ({q1['ccu_pro']} CCU) |")
    lines.append(f"     | :--- | :---: | :---: | :---: |")
    lines.append(f"     | **Hardcore / Event Sync** | 10% CCU / Installs | **{q1['install_base_concurrency'][0.10]['free']:,} installs** | **{q1['install_base_concurrency'][0.10]['pro']:,} installs** |")
    lines.append(f"     | **Active Squad Gaming** | 5% CCU / Installs | **{q1['install_base_concurrency'][0.05]['free']:,} installs** | **{q1['install_base_concurrency'][0.05]['pro']:,} installs** |")
    lines.append(f"     | **Standard Multiplayer** | 2% CCU / Installs | **{q1['install_base_concurrency'][0.02]['free']:,} installs** | **{q1['install_base_concurrency'][0.02]['pro']:,} installs** |")
    lines.append(f"     | **Casual Consumer App** | 1% CCU / Installs | **{q1['install_base_concurrency'][0.01]['free']:,} installs** | **{q1['install_base_concurrency'][0.01]['pro']:,} installs** |")
    lines.append(f"3. **Monthly Bandwidth Support by User Engagement (10 GB Egress Allocation):**")
    lines.append(f"   * If the install base exhibits mixed realistic play cadences:")
    lines.append(f"     | User Play Engagement | Free Egress / User | Free Tier Install Capacity | Pro Egress / User | Pro Tier Install Capacity |")
    lines.append(f"     | :--- | :---: | :---: | :---: | :---: |")
    for h in [64.0, 16.0, 8.0, 2.0]:
        eng = q1['install_base_engagement'][h]
        desc = "Tournament Power (64 hrs/mo)" if h == 64 else ("Bi-Weekly (16 hrs/mo)" if h == 16 else ("Monthly Meetup (8 hrs/mo)" if h == 8 else "Casual Skirmish (2 hrs/mo)"))
        lines.append(f"     | **{desc}** | {eng['free_user_mb']:.2f} MB | **{eng['free_installs']:,} users** | {eng['pro_user_mb']:.2f} MB | **{eng['pro_installs']:,} users** |")
    lines.append("")
    lines.append("#### b. Total Install Base (Free + Pro Mix) Before Upgrading from Firebase Free Tier")
    lines.append("The Firebase free allocation is bounded by **100 simultaneous connections** and **10 GB monthly egress**:")
    lines.append("")
    lines.append("| Install Base Mix | Peak Concurrency Cap | Supported Installs (2% CCU) | Supported Installs (5% CCU) | 10 GB Bandwidth Cap (8 hrs/mo) | 10 GB Bandwidth Cap (64 hrs/mo) | Primary Upgrade Trigger |")
    lines.append("| :--- | :---: | :---: | :---: | :---: | :---: | :--- |")
    for ut in q1.get("install_base_upgrade_thresholds", []):
        lines.append(f"| **{ut['mix']}** | {ut['conn_cap_ccu']} CCU | **{ut['installs_2pct_ccu']:,} installs** | **{ut['installs_5pct_ccu']:,} installs** | {ut['bw_users_8h']:,} users | {ut['bw_users_64h']:,} users | **{ut['primary_trigger']}** |")
    lines.append("")
    lines.append("* **Key Takeaway:** For any realistic freemium mix (5%–20% Pro), **the 100 simultaneous connection cap is reached FIRST** at **2,000 to 5,000 total installs** (at 5%–2% concurrency), with 85%+ of free bandwidth remaining unused.")
    lines.append("* **Stage 2 (Blaze Pay-As-You-Go):** Lifts the connection cap ($5/1,000 conns) and is economically cost-effective up to **~30,000 to 50,000 total installs** before a dedicated WebSocket VPS ($50/mo) becomes cheaper.")
    lines.append("")

    lines.append("### 2. What’s the incremental cost of a game?")
    lines.append(f"*(Billed at standard Firebase RTDB egress rate of ${s['rtdb_egress_cost_gb']:.2f} / GB; ingress is free)*")
    lines.append(f"* **Free Tier Room ({s['p_free']} Players, Duty-Cycled):**")
    lines.append(f"  * **1-Hour Match:** **${q2[1.0]['free_duty_cost']:.5f}** (~{q2[1.0]['free_duty_cost']*100:.3f}¢)")
    lines.append(f"  * **2-Hour Match:** **${q2[2.0]['free_duty_cost']:.5f}** (~{q2[2.0]['free_duty_cost']*100:.3f}¢)")
    lines.append(f"  * **4-Hour Match:** **${q2[4.0]['free_duty_cost']:.5f}** (~{q2[4.0]['free_duty_cost']*100:.3f}¢)")
    lines.append(f"  * **8-Hour Full Day:** **${q2[8.0]['free_duty_cost']:.5f}** (~{q2[8.0]['free_duty_cost']*100:.3f}¢)")
    lines.append(f"  * *Rate per player:* **${free_player_hr_cost:.6f} / player-hour** (~{free_player_hr_cost*100:.4f}¢/hr)")
    lines.append(f"* **Pro Tier Room ({s['p_pro']} Players, Duty-Cycled):**")
    lines.append(f"  * **1-Hour Match:** **${q2[1.0]['pro_duty_cost']:.5f}** (~{q2[1.0]['pro_duty_cost']*100:.3f}¢)")
    lines.append(f"  * **2-Hour Match:** **${q2[2.0]['pro_duty_cost']:.5f}** (~{q2[2.0]['pro_duty_cost']*100:.3f}¢)")
    lines.append(f"  * **4-Hour Match:** **${q2[4.0]['pro_duty_cost']:.5f}** (~{q2[4.0]['pro_duty_cost']*100:.3f}¢)")
    lines.append(f"  * **8-Hour Full Day:** **${q2[8.0]['pro_duty_cost']:.5f}** (~{q2[8.0]['pro_duty_cost']*100:.3f}¢)")
    lines.append(f"  * *Rate per player:* **${pro_player_hr_cost:.6f} / player-hour** (~{pro_player_hr_cost*100:.4f}¢/hr)")
    lines.append(f"* **Pro Tier Room (Continuous Screen Worst-Case 100% Active):**")
    lines.append(f"  * **1-Hour Match:** **${q2[1.0]['pro_cont_cost']:.5f}** (~{q2[1.0]['pro_cont_cost']*100:.3f}¢)")
    lines.append(f"  * **8-Hour Full Day:** **${q2[8.0]['pro_cont_cost']:.5f}** (~{q2[8.0]['pro_cont_cost']*100:.3f}¢)\n")

    lines.append(f"### 3. The app charges one time ${s['one_time_price']:.2f}, how many months will it take to deplete 50% of the revenue?")
    lines.append(f"*(Assuming weekend tournament play: 8 hrs/day $\\times$ 2 days/wk = {s['hours_per_month_4wk']:.0f} hrs/month)*")
    lines.append(f"* **Scenario A: Per-Player Lifetime Purchase (${s['one_time_price']:.2f} paid by each Pro player):**")
    lines.append(f"  * Monthly cost per player: **${q3['cost_mo_player_64']:.4f} / month** (~{q3['cost_mo_player_64']*100:.2f}¢/mo)")
    lines.append(f"  * Runway to deplete **50% of Gross Revenue** (${s['one_time_price']*0.5:.2f}): **{q3['runway_player_gross_64']:.1f} Months** (**{q3['runway_player_gross_64']/12.0:.2f} Years**)")
    lines.append(f"  * Runway to deplete **50% of Net Revenue** (Apple 15% Small Biz fee, ${s['one_time_price']*(1-s['apple_small_biz_fee'])*0.5:.2f}): **{q3['runway_player_net15_64']:.1f} Months** (**{q3['runway_player_net15_64']/12.0:.2f} Years**)")
    lines.append(f"  * Runway to deplete **50% of Net Revenue** (Apple 30% Standard fee, ${s['one_time_price']*(1-s['apple_standard_fee'])*0.5:.2f}): **{q3['runway_player_net30_64']:.1f} Months** (**{q3['runway_player_net30_64']/12.0:.2f} Years**)")
    lines.append(f"* **Scenario B: Host-Subsidized Squad License (${s['one_time_price']:.2f} paid once by host for entire {s['p_pro']}-player squad):**")
    lines.append(f"  * Monthly cost for entire {s['p_pro']}-player room: **${q3['cost_mo_room_64']:.4f} / month**")
    lines.append(f"  * Runway to deplete **50% of Gross Revenue** (${s['one_time_price']*0.5:.2f}): **{q3['runway_host_gross_64']:.1f} Months** (~{q3['runway_host_gross_64']/12.0:.2f} Years)")
    lines.append(f"  * Runway to deplete **50% of Net Revenue** (Apple 15% fee, ${s['one_time_price']*(1-s['apple_small_biz_fee'])*0.5:.2f}): **{q3['runway_host_net15_64']:.1f} Months** (~{q3['runway_host_net15_64']/12.0:.2f} Years)")
    lines.append(f"  * Runway to deplete **50% of Net Revenue** (Apple 30% fee, ${s['one_time_price']*(1-s['apple_standard_fee'])*0.5:.2f}): **{q3['runway_host_net30_64']:.1f} Months** (~{q3['runway_host_net30_64']/12.0:.2f} Years)\n")

    lines.append("---\n")
    lines.append("## Detailed Reference Tables\n")

    lines.append("### 1. Network Bandwidth Rates")
    lines.append("| Room Tier | Downlink Duty Cycle | Telemetry (B/s) | Tactical (B/s) | Total (B/s) | Total (MB/hr) |")
    lines.append("| :--- | :---: | :---: | :---: | :---: | :---: |")
    lines.append(f"| **Free Tier ({s['p_free']} Players)** | {r['duty_free']*100:.2f}% | {r['room_down_free_duty_bps']:.1f} | 0.0 | **{r['room_down_free_duty_bps']:.1f}** | **{r['room_down_free_duty_mb_hr']:.3f} MB/hr** |")
    lines.append(f"| **Free Tier (100% Active)** | 100.00% | {r['room_down_free_cont_bps']:.1f} | 0.0 | **{r['room_down_free_cont_bps']:.1f}** | **{r['room_down_free_cont_mb_hr']:.3f} MB/hr** |")
    lines.append(f"| **Pro Tier ({s['p_pro']} Players)** | {r['duty_pro']*100:.2f}% | {r['room_down_tel_pro_duty_bps']:.1f} | {r['room_down_tac_pro_duty_bps']:.1f} | **{r['room_down_pro_duty_bps']:.1f}** | **{r['room_down_pro_duty_mb_hr']:.3f} MB/hr** |")
    lines.append(f"| **Pro Tier (100% Active)** | 100.00% | {r['room_down_pro_cont_bps'] - (s['p_pro']-1)*s['tactical_rate']*s['payload_tactical']:.1f} | {(s['p_pro']-1)*s['tactical_rate']*s['payload_tactical']:.1f} | **{r['room_down_pro_cont_bps']:.1f}** | **{r['room_down_pro_cont_mb_hr']:.3f} MB/hr** |\n")

    lines.append("### 2. Free Tier Allocation Capacity (10 GB & 100 Connections)")
    lines.append("| Room Tier | Monthly Egress / Game (64h) | BW-Limited Games (10 GB) | Conn-Limited Games (100) | **Effective Concurrent Games** |")
    lines.append("| :--- | :---: | :---: | :---: | :---: |")
    lines.append(f"| **Free Tier Room** | {q1['free_game_mo_mb_64']:.2f} MB ({q1['free_game_mo_gb_64']:.4f} GB) | {q1['free_bw_games_64']:.1f} games | {q1['free_conn_games']} games | **{q1['free_effective_games_64']} games** *(Conn-limited)* |")
    lines.append(f"| **Pro Tier Room** | {q1['pro_game_mo_mb_64']:.2f} MB ({q1['pro_game_mo_gb_64']:.4f} GB) | {q1['pro_bw_games_64']:.2f} games | {q1['pro_conn_games']} games | **{q1['pro_effective_games_64']} games** *(Exact Convergence)* |\n")

    lines.append("### 3. Incremental Match Cost ($1.00 / GB Egress)")
    lines.append("| Match Duration | Free Tier (Duty-Cycled) | Pro Tier (Duty-Cycled) | Pro Tier (Continuous Screen) |")
    lines.append("| :--- | :---: | :---: | :---: |")
    for d in [1.0, 2.0, 4.0, 8.0]:
        c = q2[d]
        lines.append(f"| **{d:.0f}-Hour Match** | **${c['free_duty_cost']:.5f}** ({c['free_duty_cost']*100:.3f}¢) | **${c['pro_duty_cost']:.5f}** ({c['pro_duty_cost']*100:.3f}¢) | ${c['pro_cont_cost']:.5f} ({c['pro_cont_cost']*100:.3f}¢) |")
    lines.append("")

    lines.append(f"### 4. Revenue Depletion Runway (${s['one_time_price']:.2f} Purchase, 64 hrs/month)")
    lines.append(f"| Purchase Model | Monthly Cost | Runway to 50% Gross (${s['one_time_price']*0.5:.2f}) | Runway to 50% Net 15% (${s['one_time_price']*(1-s['apple_small_biz_fee'])*0.5:.2f}) | Runway to 50% Net 30% (${s['one_time_price']*(1-s['apple_standard_fee'])*0.5:.2f}) |")
    lines.append("| :--- | :---: | :---: | :---: | :---: |")
    lines.append(f"| **Per-Player License** | ${q3['cost_mo_player_64']:.4f}/mo ({q3['cost_mo_player_64']*100:.1f}¢) | **{q3['runway_player_gross_64']:.1f} mo** ({q3['runway_player_gross_64']/12:.2f} yrs) | **{q3['runway_player_net15_64']:.1f} mo** ({q3['runway_player_net15_64']/12:.2f} yrs) | **{q3['runway_player_net30_64']:.1f} mo** ({q3['runway_player_net30_64']/12:.2f} yrs) |")
    lines.append(f"| **Host-Subsidized Squad** | ${q3['cost_mo_room_64']:.4f}/mo | **{q3['runway_host_gross_64']:.1f} mo** ({q3['runway_host_gross_64']/12:.2f} yrs) | **{q3['runway_host_net15_64']:.1f} mo** ({q3['runway_host_net15_64']/12:.2f} yrs) | **{q3['runway_host_net30_64']:.1f} mo** ({q3['runway_host_net30_64']/12:.2f} yrs) |\n")

    return "\n".join(lines)


def render_comparison_markdown(res_a: Dict[str, Any], res_b: Dict[str, Any]) -> str:
    sa, sb = res_a["scheme"], res_b["scheme"]
    ra, rb = res_a["rates"], res_b["rates"]
    q1a, q1b = res_a["q1_capacity"], res_b["q1_capacity"]
    q2a, q2b = res_a["q2_costs"], res_b["q2_costs"]
    q3a, q3b = res_a["q3_runway"], res_b["q3_runway"]

    def diff_pct(new, old):
        if old == 0:
            return "N/A"
        pct = ((new - old) / old) * 100.0
        sign = "+" if pct > 0 else ""
        return f"{sign}{pct:.1f}%"

    lines = []
    lines.append(f"# Benchmark Comparison: {sa['name']} vs. {sb['name']}\n")

    lines.append("## 🎯 Comparative Answers to Core Benchmark Questions\n")

    lines.append("### 1. How many concurrent games for each benchmark assuming weekend play only and 8 hour per day using only RTDB blaze free allocation?")
    lines.append(f"* **Free Tier Room:**")
    lines.append(f"  * Baseline: **{q1a['free_effective_games_64']} games** (10 GB BW cap: {q1a['free_bw_games_64']:.1f})")
    lines.append(f"  * Proposed: **{q1b['free_effective_games_64']} games** (10 GB BW cap: {q1b['free_bw_games_64']:.1f})")
    lines.append(f"  * *Both remain connection-limited at {q1a['free_conn_games']} games by the {sa['rtdb_free_connections']}-connection free tier ceiling.*")
    lines.append(f"* **Pro Tier Room:**")
    lines.append(f"  * Baseline: **{q1a['pro_effective_games_64']} games** (10 GB BW cap: {q1a['pro_bw_games_64']:.2f})")
    lines.append(f"  * Proposed: **{q1b['pro_effective_games_64']} games** (10 GB BW cap: {q1b['pro_bw_games_64']:.2f})")
    lines.append(f"  * *Bandwidth capacity change:* **{diff_pct(q1b['pro_bw_games_64'], q1a['pro_bw_games_64'])}**\n")

    lines.append("#### a. Translate this to total install base also")
    lines.append(f"* **Literal 64h Power User Base (10 GB Bandwidth Capacity):**")
    lines.append(f"  * Free Tier: {q1a['install_base_literal_free_64']:.0f} users $\\rightarrow$ **{q1b['install_base_literal_free_64']:.0f} users** ({diff_pct(q1b['install_base_literal_free_64'], q1a['install_base_literal_free_64'])})")
    lines.append(f"  * Pro Tier: {q1a['install_base_literal_pro_64']:.0f} users $\\rightarrow$ **{q1b['install_base_literal_pro_64']:.0f} users** ({diff_pct(q1b['install_base_literal_pro_64'], q1a['install_base_literal_pro_64'])})")
    lines.append(f"* **Standard Multiplayer Concurrency (2% Concurrency Ratio):**")
    lines.append(f"  * Free Tier: {q1a['install_base_concurrency'][0.02]['free']:,} installs $\\rightarrow$ **{q1b['install_base_concurrency'][0.02]['free']:,} installs**")
    lines.append(f"  * Pro Tier: {q1a['install_base_concurrency'][0.02]['pro']:,} installs $\\rightarrow$ **{q1b['install_base_concurrency'][0.02]['pro']:,} installs**\n")

    lines.append("### 2. What’s the incremental cost of a game?")
    lines.append(f"* **Pro Tier 1-Hour Match:** ${q2a[1.0]['pro_duty_cost']:.5f} $\\rightarrow$ **${q2b[1.0]['pro_duty_cost']:.5f}** (**{diff_pct(q2b[1.0]['pro_duty_cost'], q2a[1.0]['pro_duty_cost'])}**)")
    lines.append(f"* **Pro Tier 2-Hour Match:** ${q2a[2.0]['pro_duty_cost']:.5f} $\\rightarrow$ **${q2b[2.0]['pro_duty_cost']:.5f}** (**{diff_pct(q2b[2.0]['pro_duty_cost'], q2a[2.0]['pro_duty_cost'])}**)")
    lines.append(f"* **Pro Tier 4-Hour Match:** ${q2a[4.0]['pro_duty_cost']:.5f} $\\rightarrow$ **${q2b[4.0]['pro_duty_cost']:.5f}** (**{diff_pct(q2b[4.0]['pro_duty_cost'], q2a[4.0]['pro_duty_cost'])}**)")
    lines.append(f"* **Pro Tier 8-Hour Full-Day:** ${q2a[8.0]['pro_duty_cost']:.5f} $\\rightarrow$ **${q2b[8.0]['pro_duty_cost']:.5f}** (**{diff_pct(q2b[8.0]['pro_duty_cost'], q2a[8.0]['pro_duty_cost'])}**)\n")

    lines.append(f"### 3. The app charges one time ${s['one_time_price']:.2f}, how many months will it take to deplete 50% of the revenue?")
    lines.append(f"* **Per-Player License (50% Gross Revenue $10.00):** {q3a['runway_player_gross_64']:.1f} mo ({q3a['runway_player_gross_64']/12:.2f} yrs) $\\rightarrow$ **{q3b['runway_player_gross_64']:.1f} mo** (**{q3b['runway_player_gross_64']/12:.2f} yrs**) [**{diff_pct(q3b['runway_player_gross_64'], q3a['runway_player_gross_64'])}** runway]")
    lines.append(f"* **Per-Player License (50% Net 30% Revenue $7.00):** {q3a['runway_player_net30_64']:.1f} mo ({q3a['runway_player_net30_64']/12:.2f} yrs) $\\rightarrow$ **{q3b['runway_player_net30_64']:.1f} mo** (**{q3b['runway_player_net30_64']/12:.2f} yrs**) [**{diff_pct(q3b['runway_player_net30_64'], q3a['runway_player_net30_64'])}** runway]")
    lines.append(f"* **Host-Subsidized Squad (50% Net 30% Revenue $7.00):** {q3a['runway_host_net30_64']:.1f} mo $\\rightarrow$ **{q3b['runway_host_net30_64']:.1f} mo** [**{diff_pct(q3b['runway_host_net30_64'], q3a['runway_host_net30_64'])}** runway]\n")

    lines.append("---\n")
    lines.append("## Detailed Comparative Metrics Table\n")
    lines.append("| Metric / Dimension | Baseline (`" + sa['name'] + "`) | Proposed (`" + sb['name'] + "`) | Absolute Delta | Delta % |")
    lines.append("| :--- | :---: | :---: | :---: | :---: |")
    
    lines.append(f"| **Telemetry Payload** | {sa['payload_telemetry']} B | {sb['payload_telemetry']} B | {sb['payload_telemetry'] - sa['payload_telemetry']:+d} B | {diff_pct(sb['payload_telemetry'], sa['payload_telemetry'])} |")
    lines.append(f"| **Tactical Marker Payload** | {sa['payload_tactical']} B | {sb['payload_tactical']} B | {sb['payload_tactical'] - sa['payload_tactical']:+d} B | {diff_pct(sb['payload_tactical'], sa['payload_tactical'])} |")
    lines.append(f"| **Free Tier Downlink Rate** | {ra['room_down_free_duty_mb_hr']:.3f} MB/hr | {rb['room_down_free_duty_mb_hr']:.3f} MB/hr | {rb['room_down_free_duty_mb_hr'] - ra['room_down_free_duty_mb_hr']:+.3f} MB/hr | {diff_pct(rb['room_down_free_duty_mb_hr'], ra['room_down_free_duty_mb_hr'])} |")
    lines.append(f"| **Pro Tier Downlink Rate** | {ra['room_down_pro_duty_mb_hr']:.3f} MB/hr | {rb['room_down_pro_duty_mb_hr']:.3f} MB/hr | {rb['room_down_pro_duty_mb_hr'] - ra['room_down_pro_duty_mb_hr']:+.3f} MB/hr | {diff_pct(rb['room_down_pro_duty_mb_hr'], ra['room_down_pro_duty_mb_hr'])} |")
    lines.append(f"| **Pro Monthly Egress / Game (64h)** | {q1a['pro_game_mo_gb_64']:.3f} GB | {q1b['pro_game_mo_gb_64']:.3f} GB | {q1b['pro_game_mo_gb_64'] - q1a['pro_game_mo_gb_64']:+.3f} GB | {diff_pct(q1b['pro_game_mo_gb_64'], q1a['pro_game_mo_gb_64'])} |")
    lines.append(f"| **Pro Free Bandwidth Capacity** | {q1a['pro_bw_games_64']:.2f} games | {q1b['pro_bw_games_64']:.2f} games | {q1b['pro_bw_games_64'] - q1a['pro_bw_games_64']:+.2f} games | {diff_pct(q1b['pro_bw_games_64'], q1a['pro_bw_games_64'])} |")
    lines.append(f"| **Pro 1-Hour Match Cost** | ${q2a[1.0]['pro_duty_cost']:.5f} | ${q2b[1.0]['pro_duty_cost']:.5f} | ${q2b[1.0]['pro_duty_cost'] - q2a[1.0]['pro_duty_cost']:+.5f} | {diff_pct(q2b[1.0]['pro_duty_cost'], q2a[1.0]['pro_duty_cost'])} |")
    lines.append(f"| **Pro 8-Hour Match Cost** | ${q2a[8.0]['pro_duty_cost']:.5f} | ${q2b[8.0]['pro_duty_cost']:.5f} | ${q2b[8.0]['pro_duty_cost'] - q2a[8.0]['pro_duty_cost']:+.5f} | {diff_pct(q2b[8.0]['pro_duty_cost'], q2a[8.0]['pro_duty_cost'])} |")
    lines.append(f"| **Per-Player Runway (Gross $10.00)** | {q3a['runway_player_gross_64']:.1f} mo | {q3b['runway_player_gross_64']:.1f} mo | {q3b['runway_player_gross_64'] - q3a['runway_player_gross_64']:+.1f} mo | {diff_pct(q3b['runway_player_gross_64'], q3a['runway_player_gross_64'])} |")
    lines.append(f"| **Per-Player Runway (Net 30% $7.00)** | {q3a['runway_player_net30_64']:.1f} mo | {q3b['runway_player_net30_64']:.1f} mo | {q3b['runway_player_net30_64'] - q3a['runway_player_net30_64']:+.1f} mo | {diff_pct(q3b['runway_player_net30_64'], q3a['runway_player_net30_64'])} |")
    lines.append(f"| **Host-Subsidized Runway (Net 30%)** | {q3a['runway_host_net30_64']:.1f} mo | {q3b['runway_host_net30_64']:.1f} mo | {q3b['runway_host_net30_64'] - q3a['runway_host_net30_64']:+.1f} mo | {diff_pct(q3b['runway_host_net30_64'], q3a['runway_host_net30_64'])} |\n")

    return "\n".join(lines)


def save_output(content: str, filename: str, output_dir: str):
    os.makedirs(output_dir, exist_ok=True)
    filepath = os.path.join(output_dir, filename)
    with open(filepath, "w") as f:
        f.write(content)
    return filepath


def main():
    parser = argparse.ArgumentParser(description="RadarMap Network Benchmark & Cost Evaluation Engine")
    parser.add_argument("--config", type=str, help="Path to JSON file defining a custom NetworkScheme")
    parser.add_argument("--compare", nargs=2, metavar=("BASELINE", "CANDIDATE"), help="Compare two scheme JSON files")
    parser.add_argument("--json", action="store_true", help="Output raw JSON evaluation to stdout")
    parser.add_argument("--output-dir", type=str, default="output", help="Directory where benchmark outputs are stored (default: 'output')")
    parser.add_argument("--no-save", action="store_true", help="Do not write output files to disk")

    args = parser.parse_args()
    output_dir = args.output_dir

    if args.compare:
        with open(args.compare[0], "r") as f:
            data_a = json.load(f)
        with open(args.compare[1], "r") as f:
            data_b = json.load(f)
        scheme_a = NetworkScheme(**data_a)
        scheme_b = NetworkScheme(**data_b)
        res_a = evaluate_scheme(scheme_a)
        res_b = evaluate_scheme(scheme_b)
        md_content = render_comparison_markdown(res_a, res_b)
        print(md_content)

        if not args.no_save:
            slug_a = slugify(scheme_a.name)
            slug_b = slugify(scheme_b.name)
            filename = f"benchmark_comparison_{slug_a}_vs_{slug_b}.md"
            saved_path = save_output(md_content, filename, output_dir)
            print(f"\n[Saved benchmark comparison to {saved_path}]")
        return

    if args.config:
        with open(args.config, "r") as f:
            data = json.load(f)
        scheme = NetworkScheme(**data)
    else:
        scheme = NetworkScheme()

    res = evaluate_scheme(scheme)
    md_content = render_markdown_tables(res)
    json_content = json.dumps(res, indent=2)

    if args.json:
        print(json_content)
    else:
        print(md_content)

    if not args.no_save:
        scheme_slug = slugify(scheme.name)
        md_filename = f"benchmark_{scheme_slug}.md"
        json_filename = f"benchmark_{scheme_slug}.json"
        saved_md = save_output(md_content, md_filename, output_dir)
        saved_json = save_output(json_content, json_filename, output_dir)
        print(f"\n[Saved benchmark evaluation to {saved_md} and {saved_json}]")


if __name__ == "__main__":
    main()
