# IOS XE EasyPSK helper for FreeRADIUS `rlm_perl`

> [!NOTE]
> **Status: legacy Perl fallback.** This helper remains useful with stock
> FreeRADIUS 3.2.x installations that do not include native Cisco EasyPSK
> preprocessing. A binary-safe C implementation has been submitted upstream
> as [FreeRADIUS PR #5921](https://github.com/FreeRADIUS/freeradius-server/pull/5921)
> and does not require `rlm_perl`.

This repository contains a small `rlm_perl` helper for non-FT IOS XE EasyPSK
request normalization on FreeRADIUS 3.2.x.

The current design is intentionally narrow:
- the Perl helper only normalizes Cisco request attributes into the generic DPSK attributes that `rlm_dpsk` already consumes
- vendor-specific reply attributes are generated in `policy.d/dpsk`
- VLAN assignment is handled by the updated `rlm_dpsk` module via standard tunnel reply attributes

This reflects what worked best during interoperability testing with IOS XE EasyPSK, Meraki EasyPSK, and Ruckus DPSK.

## What this helper does

IOS XE EasyPSK sends the handshake material in `Cisco-AVPair`, including binary payloads such as:
- `cisco-anonce`
- `cisco-8021x-data`
- `cisco-bssid`
- `cisco-wlan-ssid`

This helper:
- decodes Cisco escaped AVPair strings
- extracts the EasyPSK fields above
- populates the generic FreeRADIUS DPSK request attributes:
  - `FreeRADIUS-802.1X-Anonce`
  - `FreeRADIUS-802.1X-EAPoL-Key-Msg`
  - `Called-Station-MAC`
  - `Called-Station-SSID`

That is enough for `rlm_dpsk` to do the key matching.

## What this helper no longer does

The helper does **not** generate Cisco reply AVPairs anymore.

The newer approach is:
- let `rlm_dpsk` expose generic reply attributes
- use local policy to translate those into vendor-specific replies

For IOS XE EasyPSK that means:
- `reply:Pre-Shared-Key` is turned into `Cisco-AVPair += "psk=..."`
- `Cisco-AVPair += "psk-mode=ascii"` is added in policy
- if VLAN is configured in `psk.csv`, the updated `rlm_dpsk` returns standard tunnel attributes directly

## Why this split is better

This split matched the current FreeRADIUS 3.2.x implementation work better than the older Perl-heavy approach.

It keeps responsibilities clear:
- Perl: Cisco request normalization only
- `rlm_dpsk`: generic DPSK matching and generic reply attributes
- `policy.d/dpsk`: vendor-specific reply formatting

It also aligns with the native design proposed in
[FreeRADIUS PR #5921](https://github.com/FreeRADIUS/freeradius-server/pull/5921):
keep `rlm_dpsk` vendor-neutral and perform the binary-safe Cisco-specific
request parsing in `rlm_preprocess`.

## Expected FreeRADIUS layout

Typical paths:
- FreeBSD: `/usr/local/etc/raddb`
- many Linux systems: `/etc/raddb`
- Ubuntu FreeRADIUS 3 packages: `/etc/freeradius/3.0`

This repository ships the Perl helper and documentation. The policy examples below assume a Linux-style `/etc/freeradius` tree; adjust paths for your platform.

## Minimal module definition

Example `mods-available/cisco_easy_psk_perl`:

```text
perl cisco_easy_psk_perl {
	filename = /etc/freeradius/mods-config/perl/cisco_easy_psk_perl.pl
	func_authorize = authorize
}
```

## Minimal policy usage

In `policy.d/dpsk`:

```text
cisco_easy_psk {
	if (&Cisco-AVPair[*]) {
		cisco_easy_psk_perl
	}
	else {
		noop
	}
}

cisco_easy_psk_reply {
	if (&request:Cisco-AVPair[*] && &reply:Pre-Shared-Key) {
		update reply {
			&Cisco-AVPair += "psk=%{reply:Pre-Shared-Key}"
			&Cisco-AVPair += "psk-mode=ascii"
		}
		updated
	}
	else {
		noop
	}
}
```

Then call those policies from `sites-enabled/default` around `dpsk`.

## Important note about the Cisco reply format

The current working policy returns:
- `Cisco-AVPair += "psk=%{reply:Pre-Shared-Key}"`
- `Cisco-AVPair += "psk-mode=ascii"`

This is based on the updated `rlm_dpsk` behavior where `reply:Pre-Shared-Key` is exposed directly. Earlier experiments also tested PMK-hex based Cisco replies, but the current implementation path documented here is the simpler ASCII PSK reply driven from local policy.

## VLAN handling

With the updated `rlm_dpsk`, `psk.csv` can now be written as:

```text
identity,psk[,mac[,vlanid]]
```

Examples:

```text
00220022,00220022
vlan2065,00330033,,2065
00550055,00550055,a0d36578f384
00660066,00660066,f44ee3989fe0
```

If `vlanid` is present, `rlm_dpsk` returns:
- `Tunnel-Type = VLAN`
- `Tunnel-Medium-Type = IEEE-802`
- `Tunnel-Private-Group-Id = "<vlanid>"`

This means Cisco, Meraki, and Ruckus can all share the same generic DPSK decision while still formatting the final vendor reply differently in policy.

## Current recommendation

For an unmodified stock FreeRADIUS 3.2.x installation that does not include
[PR #5921](https://github.com/FreeRADIUS/freeradius-server/pull/5921):
- use policy to normalize Ruckus and Meraki requests into generic DPSK attributes
- use this Perl helper only as a legacy Cisco request-normalization fallback
- use `rlm_dpsk` for matching
- use local policy for vendor-specific replies
- configure Fast Transition as Disabled when FT-capable stations use this path

For new custom builds, prefer the binary-safe C implementation from
[PR #5921](https://github.com/FreeRADIUS/freeradius-server/pull/5921). It moves
the Cisco-specific request normalization into `rlm_preprocess` and removes the
runtime dependency on `rlm_perl`.

## Status of the C implementation

A C implementation has been validated on FreeRADIUS 3.2.x and submitted
upstream as [PR #5921](https://github.com/FreeRADIUS/freeradius-server/pull/5921).
It decodes IOS XE EasyPSK `Cisco-AVPair` data inside `rlm_preprocess` and writes
the decoded results to `Tmp-String-0` and `Tmp-Octets-0..2`. Local policy then
maps those temporary attributes to the generic DPSK request attributes before
calling `rlm_dpsk`.

That design successfully authenticated IOS XE EasyPSK requests without the
Perl helper. PR #5921 is currently open; it covers non-FT PSK handshakes and
explicitly rejects fragmented FT-PSK input.

FT Adaptive support is tracked in
[issue #5912](https://github.com/FreeRADIUS/freeradius-server/issues/5912).
A C-only follow-up implementation has been validated in the fork on branch
[`test/cisco-easypsk-ft-adaptive-20260815`](https://github.com/hshimomura/freeradius-server/tree/test/cisco-easypsk-ft-adaptive-20260815),
including fragmented EAPOL-Key reassembly and FT-PSK validation. The plan is to
prepare that work as a separate upstream pull request after PR #5921 is merged.

In short:
- Perl helper: legacy non-FT fallback for stock FreeRADIUS 3.2.x deployments
- C `rlm_preprocess` version: preferred implementation proposed in PR #5921
- FT Adaptive: validated C-only follow-up, to be proposed after PR #5921

## Additional notes

See [CURRENT_FREERADIUS_DPSK_EASYPSK_NOTES.md](./CURRENT_FREERADIUS_DPSK_EASYPSK_NOTES.md) for:
- implementation lessons learned
- recommended configuration items
- a larger sample `policy.d/dpsk`
- notes about Cisco, Meraki, and Ruckus behavior
