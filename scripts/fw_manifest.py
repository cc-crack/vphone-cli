#!/usr/bin/env python3
"""Generate hybrid BuildManifest.plist and Restore.plist for vresearch1 restore.

Merges cloudOS boot-chain (vresearch101ap) with a compatible runtime component
set and iPhone OS images into a single DFU erase-install Build Identity.

The VM hardware identifies as vresearch101ap (BDID 0x90) in DFU mode, so the
identity fields must match for TSS/SHSH signing.  Older cloudOS builds expose a
vphone600 runtime variant whose device tree sets MKB dt=1 (keybag-less boot).
Newer cloudOS builds removed vphone600, so we fall back to the vresearch101
runtime components when that variant is absent.

Usage:
    python3 fw_manifest.py <iphone_dir> <cloudos_dir>
"""

import copy, os, plistlib, sys


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def load(path):
    with open(path, "rb") as f:
        return plistlib.load(f)


def entry(identities, idx, key):
    """Deep-copy a single Manifest entry from a build identity."""
    return copy.deepcopy(identities[idx]["Manifest"][key])


def has_entry(identities, idx, key):
    """Return true if a Manifest entry exists in a build identity."""
    return key in identities[idx].get("Manifest", {})


# ---------------------------------------------------------------------------
# Identity discovery
# ---------------------------------------------------------------------------


def _is_research(bi):
    """Determine whether a build identity is a research variant."""
    for comp in ("LLB", "iBSS", "iBEC"):
        path = bi.get("Manifest", {}).get(comp, {}).get("Info", {}).get("Path", "")
        if not path:
            continue
        parts = os.path.basename(path).split(".")
        if len(parts) == 4:
            return "RESEARCH" in parts[2]
    variant = bi.get("Info", {}).get("Variant", "")
    return "research" in variant.lower()


def find_cloudos(identities, device_class):
    """Find release and research identity indices for the given DeviceClass."""
    release = research = None
    for i, bi in enumerate(identities):
        dc = bi.get("Info", {}).get("DeviceClass", "")
        if dc != device_class:
            continue
        if _is_research(bi):
            if research is None:
                research = i
        else:
            if release is None:
                release = i
    if release is None:
        raise KeyError(f"No release identity for DeviceClass={device_class}")
    if research is None:
        raise KeyError(f"No research identity for DeviceClass={device_class}")
    return release, research


def find_cloudos_optional(identities, device_class):
    """Return release/research identity indices, or None when absent."""
    try:
        return find_cloudos(identities, device_class)
    except KeyError:
        return None


def find_iphone_erase(identities):
    """Return the index of the first iPhone erase identity."""
    for i, bi in enumerate(identities):
        var = bi.get("Info", {}).get("Variant", "").lower()
        if "research" not in var and "upgrade" not in var and "recovery" not in var:
            return i
    raise KeyError("No erase identity found in iPhone manifest")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <iphone_dir> <cloudos_dir>", file=sys.stderr)
        sys.exit(1)

    iphone_dir, cloudos_dir = sys.argv[1], sys.argv[2]

    cloudos_bm = load(os.path.join(cloudos_dir, "BuildManifest.plist"))
    iphone_bm = load(os.path.join(iphone_dir, "BuildManifest.plist"))
    cloudos_rp = load(os.path.join(cloudos_dir, "Restore.plist"))
    iphone_rp = load(os.path.join(iphone_dir, "Restore.plist"))

    C = cloudos_bm["BuildIdentities"]
    I = iphone_bm["BuildIdentities"]

    # ── Discover source identities ───────────────────────────────────
    #   PROD / RES  = vresearch101ap release / research  (boot chain)
    #   VP   / VPR  = runtime release / research
    PROD, RES = find_cloudos(C, "vresearch101ap")
    runtime = find_cloudos_optional(C, "vphone600ap")
    runtime_device = "vphone600ap"
    if runtime is None:
        runtime = (PROD, RES)
        runtime_device = "vresearch101ap"
    VP, VPR = runtime
    I_ERASE = find_iphone_erase(I)

    print(f"  cloudOS vresearch101ap: release=#{PROD}, research=#{RES}")
    print(f"  cloudOS runtime ({runtime_device}): release=#{VP}, research=#{VPR}")
    print(f"  iPhone  erase: #{I_ERASE}")

    # ── Build the single DFU erase identity ──────────────────────────
    # Identity base from vresearch101ap PROD — must match DFU hardware
    # (BDID 0x90) for TSS/SHSH signing.
    bi = copy.deepcopy(C[PROD])
    bi["Manifest"] = {}
    bi["Ap,ProductType"] = "ComputeModule14,2"
    bi["Ap,Target"] = "VRESEARCH101AP"
    bi["Ap,TargetType"] = "vresearch101"
    bi["ApBoardID"] = "0x90"
    bi["ApChipID"] = "0xFE01"
    bi["ApSecurityDomain"] = "0x01"
    for k in ("NeRDEpoch", "RestoreAttestationMode"):
        bi.pop(k, None)
        bi.get("Info", {}).pop(k, None)
    bi["Info"]["FDRSupport"] = False
    bi["Info"]["Variant"] = "Darwin Cloud Customer Erase Install (IPSW)"
    bi["Info"]["VariantContents"] = {
        "BasebandFirmware": "Release",
        "DCP": "DarwinProduction",
        "DFU": "DarwinProduction",
        "Firmware": "DarwinProduction",
        "InitiumBaseband": "Production",
        "InstalledKernelCache": "Production",
        "InstalledSPTM": "Production",
        "OS": "Production",
        "RestoreKernelCache": "Production",
        "RestoreRamDisk": "Production",
        "RestoreSEP": "DarwinProduction",
        "RestoreSPTM": "Production",
        "SEP": "DarwinProduction",
        "VinylFirmware": "Release",
    }

    m = bi["Manifest"]

    # ── Boot chain (vresearch101 — matches DFU hardware) ─────────────
    m["LLB"] = entry(C, PROD, "LLB")
    m["iBSS"] = entry(C, PROD, "iBSS")
    m["iBEC"] = entry(C, PROD, "iBEC")
    m["iBoot"] = entry(C, RES, "iBoot")  # research iBoot

    # ── Security monitors (shared across board configs) ──────────────
    m["Ap,RestoreSecurePageTableMonitor"] = entry(
        C, PROD, "Ap,RestoreSecurePageTableMonitor"
    )
    m["Ap,RestoreTrustedExecutionMonitor"] = entry(
        C, PROD, "Ap,RestoreTrustedExecutionMonitor"
    )
    m["Ap,SecurePageTableMonitor"] = entry(C, PROD, "Ap,SecurePageTableMonitor")
    m["Ap,TrustedExecutionMonitor"] = entry(C, RES, "Ap,TrustedExecutionMonitor")

    # ── Device tree (runtime variant)
    m["DeviceTree"] = entry(C, VP, "DeviceTree")
    m["RestoreDeviceTree"] = entry(C, VP, "RestoreDeviceTree")

    # ── SEP (matches device tree) ────────────────────────────────────
    m["SEP"] = entry(C, VP, "SEP")
    m["RestoreSEP"] = entry(C, VP, "RestoreSEP")

    # ── Kernel (patched by the Swift firmware pipeline) ───────────────
    m["KernelCache"] = entry(C, VPR, "KernelCache")  # research
    m["RestoreKernelCache"] = entry(C, VP, "RestoreKernelCache")  # release

    # ── Recovery mode (runtime variant; absent on newer vresearch101-only builds)
    if has_entry(C, VP, "RecoveryMode"):
        m["RecoveryMode"] = entry(C, VP, "RecoveryMode")

    # ── CloudOS erase ramdisk ────────────────────────────────────────
    m["RestoreRamDisk"] = entry(C, PROD, "RestoreRamDisk")
    m["RestoreTrustCache"] = entry(C, PROD, "RestoreTrustCache")

    # ── iPhone OS image ──────────────────────────────────────────────
    m["Ap,SystemVolumeCanonicalMetadata"] = entry(
        I, I_ERASE, "Ap,SystemVolumeCanonicalMetadata"
    )
    m["OS"] = entry(I, I_ERASE, "OS")
    m["StaticTrustCache"] = entry(I, I_ERASE, "StaticTrustCache")
    m["SystemVolume"] = entry(I, I_ERASE, "SystemVolume")

    # ── Assemble BuildManifest ───────────────────────────────────────
    build_manifest = {
        "BuildIdentities": [bi],
        "ManifestVersion": cloudos_bm["ManifestVersion"],
        "ProductBuildVersion": cloudos_bm["ProductBuildVersion"],
        "ProductVersion": cloudos_bm["ProductVersion"],
        "SupportedProductTypes": ["iPhone99,11"],
    }

    # ── Assemble Restore.plist ───────────────────────────────────────
    restore = {
        "ProductBuildVersion": cloudos_rp["ProductBuildVersion"],
        "ProductVersion": cloudos_rp["ProductVersion"],
        "DeviceMap": [iphone_rp["DeviceMap"][0]]
        + [
            d
            for d in cloudos_rp["DeviceMap"]
            if d["BoardConfig"] in ("vphone600ap", "vresearch101ap")
        ],
        "SupportedProductTypeIDs": {
            cat: (
                iphone_rp["SupportedProductTypeIDs"][cat]
                + cloudos_rp["SupportedProductTypeIDs"][cat]
            )
            for cat in ("DFU", "Recovery")
        },
        "SupportedProductTypes": (
            iphone_rp.get("SupportedProductTypes", [])
            + cloudos_rp.get("SupportedProductTypes", [])
        ),
        "SystemRestoreImageFileSystems": copy.deepcopy(
            iphone_rp["SystemRestoreImageFileSystems"]
        ),
    }

    # ── Write output ─────────────────────────────────────────────────
    for name, data in [
        ("BuildManifest.plist", build_manifest),
        ("Restore.plist", restore),
    ]:
        path = os.path.join(iphone_dir, name)
        with open(path, "wb") as f:
            plistlib.dump(data, f, sort_keys=True)
        print(f"  wrote {name}")


if __name__ == "__main__":
    main()
