#!/usr/bin/env python3
"""
Clean stale Placement allocations (consumer_ids with no matching live instance).

Usage:
  python3 clean_stale_allocations.py --dry-run       # default, just report
  python3 clean_stale_allocations.py --execute       # actually delete
  python3 clean_stale_allocations.py --keep <uuid>   # exclude specific UUIDs
  python3 clean_stale_allocations.py --delete <uuid> # only delete specific UUIDs

Requires: openstacksdk, and an admin context (OS_* env vars or cloud.yaml).

(c) Kurt Garloff, <s7n@garloff.de>, 10/2026
SPDX-License-Identifier: Apache 2.0
Assisted-by: Qwen3.8-27B (OpenWebUI, SearxNG)
"""

import argparse
import sys
import json
from typing import Set

import openstack


def get_conn():
    return openstack.connect()  # uses OS_* env vars or ~/.config/openstack/clouds.yaml


def list_live_instance_uuids(conn) -> Set[str]:
    """All non-deleted instances Nova knows about (all projects)."""
    uuids = set()
    for server in conn.compute.servers(all_tenants=True, limit=1000):
        uuids.add(server.id)
    return uuids


def list_rps(conn) -> list:
    """All resource providers via the Placement API."""
    rps = []
    ep = conn.placement.get_endpoint()
    marker = None
    while True:
        url = f"{ep}resource_providers" # "?limit=1000"
        if marker:
            url += f"&marker={marker}"
        #print(f"GET {url}")
        resp = conn.session.get(url)
        resp.raise_for_status()
        data = resp.json()
        #print(data["resource_providers"])
        rps.extend(data["resource_providers"])
        marker = data.get("next_marker")
        if not marker:
            break
    return rps


def list_allocations_for_rp(conn, rp_id: str, rp_nm: str) -> dict:
    """All allocation rows for one RP via GET /resource_provider/{id}/allocations."""
    allocations = {}
    ep = conn.placement.get_endpoint()
    marker = None
    while True:
        url = f"{ep}resource_providers/{rp_id}/allocations"  #?limit=1000"
        if marker:
            url += f"&marker={marker}"
        #print(f"GET {url}")
        resp = conn.session.get(url)
        resp.raise_for_status()
        data = resp.json()
        #print(data["allocations"])
        allocations.update(data["allocations"])
        marker = data.get("next_marker")
        if not marker:
            break
    for a in allocations.keys():
        allocations[a]["rp_nm"] = rp_nm
    return allocations


def delete_allocation(conn, consumer_id: str) -> bool:
    """DELETE /allocation/{consumer_id}/{rp_id}. Returns True on 204/200."""
    ep = conn.placement.get_endpoint()

    url = f"{ep}allocations/{consumer_id}"
    resp = conn.session.delete(url)
    return resp.status_code in (200, 204)


def main():
    parser = argparse.ArgumentParser(description="Clean stale Placement allocations")
    parser.add_argument("--execute", action="store_true",
                        help="Actually delete. Default is dry-run.")
    parser.add_argument("--keep", action="append", default=[],
                        help="Consumer UUIDs to skip (repeatable).")
    parser.add_argument("--delete", action="append", default=[],
                        help="Consumer UUIDs to skip (repeatable).")
    args = parser.parse_args()

    conn = get_conn()
    conn.authorize()

    # Fetch placement allocations first to avoid deleting something very new
    print("Fetching resource providers from Placement…")
    rps = list_rps(conn)
    print(f"  {len(rps)} resource providers found.")

    # Collect all (consumer_id, rp_id, resource_class, allocated) tuples
    all_allocs = {}
    for rp in rps:
        all_allocs.update(list_allocations_for_rp(conn, rp["uuid"], rp["name"]))

    print(f"  {len(all_allocs)} total consumers across all RPs.")

    print("Fetching live instances from Nova…")
    live = list_live_instance_uuids(conn)
    print(f"  {len(live)} live instances found.")

    # Identify stale consumers
    keep = set(args.keep)
    delete = set(args.delete)
    stale_consumers = sorted(
        {c for c in all_allocs.keys() if c not in live and c not in keep}
    )
    if delete:
        stale_consumers = sorted(delete)
    # Missing allocations
    missing_consumers = sorted(
        [c for c in live if not c in all_allocs]
    )

    print("To clean:")
    for stale in stale_consumers:
        print(stale)

    print(f"\n{'='*65}")
    print(f"Stale consumers to clean: {len(stale_consumers)}")
    print(f"Missing consumers: {len(missing_consumers)}")
    print(f"{'='*65}\n")

    if not stale_consumers:
        print("Nothing to clean. All allocations reference live instances.")
        return

    # Create overview by RP
    rp_stale = {}
    for stale_id in stale_consumers:
        stale = all_allocs[stale_id]
        #print(stale)
        rp_nm = stale["rp_nm"]
        dsk = stale["resources"].get("DISK_GB")
        if not rp_stale.get(rp_nm):
            rp_stale[rp_nm] = { "count": 1,
                                "VCPU": stale["resources"]["VCPU"],
                                "MEMORY_MB": stale["resources"]["MEMORY_MB"],
                                "DISK_GB": dsk if dsk else 0}
        else:
            rp_stale[rp_nm]["count"] += 1
            rp_stale[rp_nm]["VCPU"] += stale["resources"]["VCPU"]
            rp_stale[rp_nm]["MEMORY_MB"] += stale["resources"]["MEMORY_MB"]
            rp_stale[rp_nm]["DISK_GB"] += dsk if dsk else 0

    # Cleanup stats
    print("+--------------------------+------+-------+-----------+---------+")
    print("|  Resource Provider Name  | Inst | vCPUs | Memory_MB | Disk_GB |")
    print("+--------------------------+------+-------+-----------+---------+")
    for rp_nm in sorted(rp_stale.keys()):
        row = rp_stale[rp_nm]
        print(f"| {rp_nm:25s}|{row['count']:5} |{row['VCPU']:6} |{row['MEMORY_MB']:10} |{row['DISK_GB']:8} |")
    print("+--------------------------+------+-------+-----------+---------+")

    # Group by consumer for display
    if not args.execute:
        print("\n[dry-run] No changes made. Re-run with --execute to delete.")
        #return

    print(f"\nDeleting {len(stale_consumers)} allocation rows…")
    ok, fail = 0, 0
    for cid in stale_consumers:
        # GET /allocation/{consumer_id} to get the exact RP list for this consumer
        ep = conn.placement.get_endpoint()
        resp = conn.session.get(f"{ep}allocations/{cid}")
        if resp.status_code != 200:
            print(f"  WARN: cannot list allocations for {cid} (HTTP {resp.status_code})")
            fail += 1
            continue
        if args.execute:
            if delete_allocation(conn, cid):
                ok += 1
            else:
                print(f"  FAIL: {cid} / {rp_id}")
                fail += 1
    
    # TODO: Add missing allocations
    if args.execute and len(missing_consumers):
        print(f"  WARN: adding {len(missing_consumers)} missing allocations not yet supported.")

    print(f"\nDone. Deleted={ok}, Failed={fail}")
    if fail:
        sys.exit(1)


if __name__ == "__main__":
    main()
