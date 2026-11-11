#!/usr/bin/env python3
"""Delete the Route53 records external-dns created in a (public) hosted zone.

external-dns runs with --policy=upsert-only, so it never removes its own records when the
clusters are torn down — grafana/jaeger/prometheus/alertmanager/pyroscope.<domain> and
bankobs.<domain> (plus their TXT registry records) would otherwise linger in your domain's
zone forever. This removes ONLY the records external-dns owns, identified by the
`external-dns/owner=<cluster>` tag in its TXT registry records, so any other DNS you keep in
that zone is never touched. (The private obs.internal zone is handled separately by
force_destroy on the Terraform-managed zone, so it is not this script's concern.)

`make destroy` calls this automatically after `terraform destroy`. To run it by hand later
— e.g. if a destroy died before this step and the terraform outputs are already gone — pass
the zone id and owner(s) explicitly:

  python3 cleanup-external-dns-records.py --zone-id Z09... \
      --owner obs-v1-observability --owner obs-v1-bankobs [--dry-run]
"""
import argparse
import json
import subprocess
import sys

# external-dns' TXT registry names its ownership records <type>-<fqdn> (new format) and,
# during the migration it is mid-way through, also the legacy cname-<fqdn>. Strip any of
# these to recover the managed record's own name.
PREFIXES = ("a-", "aaaa-", "cname-", "txt-")


def aws(*args):
    r = subprocess.run(["aws", *args], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        sys.exit(r.returncode)
    return r.stdout


def base_name(txt_record_name):
    for p in PREFIXES:
        if txt_record_name.startswith(p):
            return txt_record_name[len(p):]
    return txt_record_name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zone-id", default="")
    ap.add_argument("--owner", action="append", default=[],
                    help="external-dns txt-owner-id (the cluster name); repeatable")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    if not a.zone_id:
        print("  (no public hosted-zone id; skipping public DNS cleanup)")
        return
    owners = [o for o in a.owner if o]
    if not owners:
        print("  (no owner ids given; skipping public DNS cleanup)")
        return

    rrsets = json.loads(aws("route53", "list-resource-record-sets",
                            "--hosted-zone-id", a.zone_id, "--output", "json"))["ResourceRecordSets"]

    # 1) find the TXT registry records this cluster owns, and the base names they guard.
    owned_bases, to_delete = set(), []
    for r in rrsets:
        if r["Type"] != "TXT":
            continue
        vals = " ".join(rr.get("Value", "") for rr in r.get("ResourceRecords", []))
        if any(("external-dns/owner=" + o) in vals for o in owners):
            to_delete.append(r)
            owned_bases.add(base_name(r["Name"]))

    # 2) add the managed A/AAAA/CNAME records that sit at those owned names.
    for r in rrsets:
        if r["Type"] in ("A", "AAAA", "CNAME") and r["Name"] in owned_bases:
            to_delete.append(r)

    if not to_delete:
        print("  no external-dns-owned records found in zone %s" % a.zone_id)
        return

    print("  %s %d external-dns record(s) in zone %s:"
          % ("would delete" if a.dry_run else "deleting", len(to_delete), a.zone_id))
    for r in to_delete:
        print("    - %-6s %s" % (r["Type"], r["Name"]))
    if a.dry_run:
        return

    # DELETE with the exact RRSet objects returned by the API, so alias and plain records
    # are both matched correctly (route53 requires an exact match to delete).
    batch = {"Changes": [{"Action": "DELETE", "ResourceRecordSet": r} for r in to_delete]}
    aws("route53", "change-resource-record-sets", "--hosted-zone-id", a.zone_id,
        "--change-batch", json.dumps(batch), "--output", "json")
    print("  ✓ public-zone external-dns records removed")


if __name__ == "__main__":
    main()
