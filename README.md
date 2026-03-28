# Cisco EasyPSK Helper for FreeRADIUS `rlm_perl`

Perl helper module for Cisco EasyPSK on FreeRADIUS 3.2.x.

As validated for this project, Cisco Identity Services Engine (ISE) 3.5 Patch 2 did not provide the EasyPSK behavior required here, so extending FreeRADIUS was necessary.

Cisco's Catalyst 9800 Easy PSK feature history states that EasyPSK was introduced in Cisco IOS XE Bengaluru 17.5.1 as an Early Field Trial feature.[^3]

This project complements `rlm_dpsk` by:

- extracting Cisco EasyPSK request parameters from `Cisco-AVPair`
- overriding `Called-Station-MAC` with the actual `cisco-bssid`
- returning Cisco EasyPSK `psk` as PMK hex
- returning `psk-mode=hex`
- optionally mapping `PSK-Identity` like `vlan2065` to tunnel VLAN attributes
- returning `cisco-easy-psk-error-cause` on reject

## Purpose

This repository was created to test Cisco EasyPSK behavior with FreeRADIUS by extending the built-in `dpsk` module with a Perl helper.

This is a test-oriented tool. It is useful for validation, reverse engineering, interoperability checks, and small-scale lab deployments, but it does not claim production-grade scale characteristics by itself.

## Solution guide and design scope

The implementation and the notes in this repository are based on these references:

- Cisco EasyPSK configuration guide:
  https://www.cisco.com/c/en/us/td/docs/wireless/controller/9800/17-6/config-guide/b_wl_17_6_cg/m_epsk.html
- Cisco EasyPSK deployment guide:
  https://www.cisco.com/c/en/us/td/docs/wireless/controller/9800/technical-reference/easy-psk-deployment-guide.html
- Cisco WPA3 / iPSK reference:
  https://www.cisco.com/c/en/us/td/docs/wireless/controller/9800/17-18/config-guide/b_wl_17_18_cg/m_wpa3.html
- Cisco private PSK / iPSK related reference:
  https://www.cisco.com/c/en/us/td/docs/wireless/controller/9800/17-6/config-guide/b_wl_17_6_cg/m_pvt_psk_ewlc.html
- FreeRADIUS `dpsk` module reference:
  https://www.freeradius.org/documentation/freeradius-server/4.0.0/reference/raddb/mods-available/dpsk.html

In practical terms:

- iPSK is the better fit when WPA3, FlexConnect, and 6 GHz readiness matter.
- EasyPSK is a WPA2-only compatibility feature and is not a fit for Wi-Fi 6E / 6 GHz.
- This FreeRADIUS approach inherits the scaling limits of candidate-PSK search in `rlm_dpsk`.

### A use case where EasyPSK can make sense

One realistic fit for EasyPSK is a small apartment building, student dormitory, or similar residential environment where:

- the operator wants one shared SSID for roaming simplicity
- each room or tenant should be isolated at Layer 2
- pre-registering every client MAC address is operationally unrealistic
- mass onboarding events and frequent high-density reconnect storms are less common than in enterprise office WLANs

In that kind of environment, using one PSK identity per room and mapping it to a room-specific VLAN can be operationally acceptable.

However, the tradeoffs remain:

- it is still WPA2-only
- a room-level PSK is shared by everyone in that room
- if that PSK leaks, the room-level secret must be rotated
- user-level accountability is weaker than with per-device credentials
- large numbers of room-specific PSKs still increase matching cost on the RADIUS side

## Why this exists

Cisco Catalyst 9800 WLC EasyPSK requests include required material in Cisco VSAs:

- `cisco-anonce`
- `cisco-8021x-data`
- `cisco-bssid`
- `cisco-wlan-ssid`

`cisco-8021x-data` is binary and is not safe to process with simple `unlang` regex captures. This module decodes the escaped payload in Perl and populates the request attributes that `rlm_dpsk` expects.

## Files

- `cisco_dpsk_rlm_perl.pl`
- `README.md`
- `README.ja.md`
- `LICENSE`

## Tested behavior

The implementation was validated with the following behavior observed in `radiusd -X`:

- successful EasyPSK authentication
- PMK returned as:
  - `Cisco-AVPair += "psk=<64-hex>"`
  - `Cisco-AVPair += "psk-mode=hex"`
- VLAN reply added only when `PSK-Identity` matches `^vlan([1-9][0-9]{0,3})$`
- password mismatch reject returns:
  - `Cisco-AVPair += "cisco-easy-psk-error-cause=2"`

## Test environment

The interoperability checks described in this repository were performed with the following environment:

- FreeBSD 14
- FreeRADIUS 3.2.8
- FreeRADIUS configuration rooted at `/usr/local/etc/raddb`

- Cisco Catalyst 9800 Wireless LAN Controller
- Version `17.18.2`

Feature introduction note:

- Cisco documents EasyPSK on Catalyst 9800 as first introduced in Cisco IOS XE Bengaluru `17.5.1`
- The 17.5.x release notes were first published on March 31, 2021, so EasyPSK support on Catalyst 9800 dates back to at least that release documentation window[^3][^4]

Path note:

- In this repository, examples use `/usr/local/etc/raddb` because the test host was FreeBSD.
- On many Linux systems, FreeRADIUS is instead rooted at `/etc/raddb`.
- On Ubuntu packages, FreeRADIUS 3 is commonly rooted at `/etc/freeradius/3.0`.

## Practical limits of this FreeRADIUS implementation

This repository implements EasyPSK matching on the FreeRADIUS side by feeding the Cisco handshake material into `rlm_dpsk` and letting it search the candidate PSKs listed in `mods-config/dpsk/psk.csv`.

That means:

- the server effectively tries candidate PSKs until one matches the handshake
- response time grows with the size of the candidate set
- large PSK inventories are not a good fit

In other words, this repository is suitable for lab work, compatibility testing, and small controlled environments, but not as a recommendation for large-scale EasyPSK production.

## Installation

Install the Perl module on the FreeRADIUS host:

```text
/usr/local/etc/raddb/mods-config/perl/cisco_dpsk_rlm_perl.pl
```

Recommended layout by platform:

- FreeBSD: `/usr/local/etc/raddb/mods-config/perl/cisco_dpsk_rlm_perl.pl`
- Linux with `/etc/raddb`: `/etc/raddb/mods-config/perl/cisco_dpsk_rlm_perl.pl`
- Ubuntu: `/etc/freeradius/3.0/mods-config/perl/cisco_dpsk_rlm_perl.pl`

Expected environment:

- FreeRADIUS 3.2.x
- `rlm_perl`
- `rlm_dpsk`
- `Digest::SHA` available to Perl

## FreeRADIUS configuration

The minimum effective additions required by this helper are:

```text
rewrite_called_station_id
perl_dpsk
dpsk
if (ok || updated) {
	update control {
		&Auth-Type := dpsk
	}
}

Auth-Type dpsk {
	dpsk
	if (updated || ok) {
		ok
	}
}

perl_dpsk

perl_dpsk
```

Placed by section, this means:

- `authorize {}`:
  - `rewrite_called_station_id`
  - `if ("%{request:Cisco-AVPair[*]}" =~ /cisco-anonce=/) { perl_dpsk; dpsk; if (ok || updated) { ... &Auth-Type := dpsk ... } }`
- `authenticate {}`:
  - `Auth-Type dpsk { dpsk; if (updated || ok) { ok } }`
- `post-auth {}`:
  - `if ("%{request:Cisco-AVPair[*]}" =~ /cisco-anonce=/) { perl_dpsk }`
- `Post-Auth-Type REJECT {}`:
  - `if ("%{request:Cisco-AVPair[*]}" =~ /cisco-anonce=/) { perl_dpsk }`

### 1. Perl module definition

Create `mods-enabled/perl_dpsk`:

```text
perl perl_dpsk {
	filename = ${modconfdir}/perl/cisco_dpsk_rlm_perl.pl
	func_authorize = authorize
	func_post_auth = post_auth
}
```

### 2. `authorize {}` in `sites-enabled/default`

Keep `rewrite_called_station_id`, then call `perl_dpsk` and `dpsk` only when the request contains EasyPSK handshake attributes.

Note:
The conditional call is recommended. Without it, ordinary MAB requests that do not carry Cisco EasyPSK handshake material can be rejected by the Perl helper.

Highlighted additions:

```diff
 # sites-enabled/default
 authorize {
 	filter_username
 	preprocess
 	chap
 	mschap
 	digest
 
+ 	rewrite_called_station_id
+	if ("%{request:Cisco-AVPair[*]}" =~ /cisco-anonce=/) {
+		perl_dpsk
+		dpsk
+		if (ok || updated) {
+			update control {
+				&Auth-Type := dpsk
+			}
+		}
+	}
 
 	suffix
 	eap
 	files
 	sql
 	expiration
 	logintime
 	pap
 }
```

```diff
authorize {
	filter_username
	preprocess
	chap
	mschap
	digest

+	rewrite_called_station_id
+	if ("%{request:Cisco-AVPair[*]}" =~ /cisco-anonce=/) {
+		perl_dpsk
+		dpsk
+		if (ok || updated) {
+			update control {
+				&Auth-Type := dpsk
+			}
+		}
+	}

	suffix
	eap
	files
	sql
	expiration
	logintime
	pap
}
```

### 3. `authenticate {}`

`rlm_dpsk` may return `updated` on success. Convert it to `ok`.

Highlighted additions:

```diff
 # sites-enabled/default
 authenticate {
+ 	Auth-Type dpsk {
+ 		dpsk
+		if (updated || ok) {
+			ok
+		}
+ 	}
 }
```

```diff
authenticate {
+	Auth-Type dpsk {
+		dpsk
+		if (updated || ok) {
+			ok
+		}
+	}
}
```

### 4. `post-auth {}`

Call `perl_dpsk` only for EasyPSK requests so successful EasyPSK replies get Cisco-specific attributes.

Note:
If `perl_dpsk` is called unconditionally here, non-EasyPSK Access-Accept replies can be polluted with EasyPSK-specific attributes or error codes.

Highlighted additions:

```diff
 # sites-enabled/default
 post-auth {
+	if ("%{request:Cisco-AVPair[*]}" =~ /cisco-anonce=/) {
+		perl_dpsk
+	}
 
 	if (&User-Name != "anonymous") {
 		sql
 	}
 	exec
 	remove_reply_message_if_eap
 }
```

```diff
post-auth {
+	if ("%{request:Cisco-AVPair[*]}" =~ /cisco-anonce=/) {
+		perl_dpsk
+	}

	if (&User-Name != "anonymous") {
		sql
	}
	exec
	remove_reply_message_if_eap
}
```

### 5. `Post-Auth-Type REJECT {}`

Call `perl_dpsk` here too, but only for EasyPSK requests, so EasyPSK rejects get `cisco-easy-psk-error-cause`.

Note:
This keeps EasyPSK reject handling available while preventing ordinary MAB rejects from being rewritten as EasyPSK failures.

Highlighted additions:

```diff
 # sites-enabled/default
 Post-Auth-Type REJECT {
 	auth_log
 	sql
 	attr_filter.access_reject
 	eap
+	if ("%{request:Cisco-AVPair[*]}" =~ /cisco-anonce=/) {
+		perl_dpsk
+	}
 	remove_reply_message_if_eap
 }
```

```diff
Post-Auth-Type REJECT {
	auth_log
	sql
	attr_filter.access_reject
	eap
+	if ("%{request:Cisco-AVPair[*]}" =~ /cisco-anonce=/) {
+		perl_dpsk
+	}
	remove_reply_message_if_eap
}
```

## How the module works

### `authorize`

Parses `Cisco-AVPair` and sets:

- `FreeRADIUS-802.1X-Anonce`
- `FreeRADIUS-802.1X-EAPoL-Key-Msg`
- `Called-Station-MAC` from `cisco-bssid`

If required input is missing:

- sets `cisco-easy-psk-error-cause=6` later in reject path

If the EAPOL frame is too short:

- sets `cisco-easy-psk-error-cause=5` later in reject path

### `post_auth`

Success path:

- reads `reply:Pre-Shared-Key`
- reads `request:Called-Station-SSID`
- derives PMK using `PBKDF2-HMAC-SHA1(passphrase, ssid, 4096, 32)`
- returns:
  - `Cisco-AVPair = "psk=<PMK-hex>"`
  - `Cisco-AVPair = "psk-mode=hex"`

Reject path:

- if `Auth-Type=dpsk` but no usable reply PSK is present, returns:
  - `Cisco-AVPair = "cisco-easy-psk-error-cause=2"`

VLAN path:

- if `PSK-Identity` matches `^vlan([1-9][0-9]{0,3})$` and the numeric VLAN is `1..4094`, returns:
  - `Tunnel-Type = VLAN`
  - `Tunnel-Medium-Type = IEEE-802`
  - `Tunnel-Private-Group-Id = <NNN>`

The regex alone would also match values above `4094`, so the module performs an additional numeric range check and suppresses VLAN reply attributes outside the valid IEEE 802.1Q VLAN range.

## `psk.csv` examples

`mods-config/dpsk/psk.csv`

`rlm_dpsk` uses CSV entries in the form:

```text
identity,psk[,mac]
```

This helper keeps the original `rlm_dpsk` meaning of `identity`. If the `identity` is `vlanNNN` and `NNN` is in the valid range `1..4094`, the helper additionally returns VLAN tunnel attributes in the Access-Accept. For any other identity value, VLAN reply attributes are not added.

When the optional `mac` column is used, `rlm_dpsk` expects a plain 12-hex-digit station MAC such as `f44ee3989fe0`.

- `f44ee3989fe0` is valid
- `f4-4e-e3-98-9f-e0` is not valid in `psk.csv`
- `f4:4e:e3:98:9f:e0` is not valid in `psk.csv`

Matching order also matters. The CSV file is read from top to bottom, and the first matching entry wins. If you mix generic rules and MAC-specific rules, place the more specific MAC-constrained entries before broader ones.

### VLAN-enabled identity

```csv
vlan2065,00330033
```

Expected reply on success:

```text
Tunnel-Type = VLAN
Tunnel-Medium-Type = IEEE-802
Tunnel-Private-Group-Id = "2065"
Cisco-AVPair += "psk=<64-hex>"
Cisco-AVPair += "psk-mode=hex"
```

### Identity without VLAN

```csv
00440044,00440044
```

Optional MAC-specific form supported by `rlm_dpsk`:

```csv
00440044,00440044,f44ee3989fe0
```

Expected reply on success:

```text
Cisco-AVPair += "psk=<64-hex>"
Cisco-AVPair += "psk-mode=hex"
```

No tunnel attributes are returned.

### Deliberate mismatch example

If the STA is configured with `00550055` but the CSV only contains:

```csv
vlan2065,00330033
00440044,00440044
```

Expected reject flow:

```text
dpsk: Failed to find matching PSK or MAC in /usr/local/etc/raddb/mods-config/dpsk/psk.csv
Sent Access-Reject ...
  Cisco-AVPair += "cisco-easy-psk-error-cause=2"
```

## Log excerpts worth checking

### Request parsing is working

```text
&request:Called-Station-MAC = ... -> '0x845a3edf8cc9'
&request:FreeRADIUS-802.1X-Anonce = ... -> '0x...'
&request:FreeRADIUS-802.1X-EAPoL-Key-Msg = ... -> '0x...'
```

### `dpsk` success

```text
dpsk: Creating &reply:PSK-Identity and &reply:Pre-Shared-Key
```

### Successful Cisco EasyPSK reply

```text
Sent Access-Accept ...
  Cisco-AVPair += "psk=<64-hex>"
  Cisco-AVPair += "psk-mode=hex"
```

### Successful VLAN reply

```text
Sent Access-Accept ...
  Tunnel-Private-Group-Id = "2065"
  Tunnel-Type = VLAN
  Tunnel-Medium-Type = IEEE-802
```

### Password mismatch

```text
dpsk: Failed to find matching PSK or MAC in /usr/local/etc/raddb/mods-config/dpsk/psk.csv
Sent Access-Reject ...
  Cisco-AVPair += "cisco-easy-psk-error-cause=2"
```

### Broken CSV

```text
dpsk: .../psk.csv[0] Failed to find ',' after identity
```

This means the CSV file itself is malformed, not that the password mismatched.

### Rule ordering example

Because the file is evaluated top to bottom, this order:

```csv
00330033,00330033
00330033,00330033,f44ee3989fe0
```

will usually match the generic entry first.

If you want the MAC-specific rule to take precedence, write it in this order:

```csv
00330033,00330033,f44ee3989fe0
00330033,00330033
```

References:

- FreeRADIUS DPSK docs:
  https://www.freeradius.org/documentation/freeradius-server/4.0.0/reference/raddb/mods-available/dpsk.html
- FreeRADIUS `rlm_dpsk.c` source:
  https://doc.freeradius.org/rlm__dpsk_8c_source.html

[^1]: FreeRADIUS DPSK module docs, CSV format and top-to-bottom read order.
[^2]: `rlm_dpsk.c` source: `token_mac` must be length 12 and is base16-decoded; file is processed sequentially.

## Notes

- `radpostauth_pkey` duplicate errors are unrelated to EasyPSK itself.
- This repository is published under the MIT License to keep reuse simple for GitHub distribution.
- Cisco ISE support should be rechecked for future releases, but this repository documents the behavior validated against ISE 3.5 Patch 2 at the time of writing.

[^3]: Cisco Catalyst 9800 Easy PSK feature history: Cisco IOS XE Bengaluru 17.5.1, released as an Early Field Trial feature. https://www.cisco.com/c/en/us/td/docs/wireless/controller/9800/17-6/config-guide/b_wl_17_6_cg/m_epsk.html
[^4]: Cisco Catalyst 9800 Cisco IOS XE Bengaluru 17.5.x release notes, first published March 31, 2021. https://www.cisco.com/c/en/us/td/docs/wireless/controller/9800/17-5/release-notes/rn-17-5-9800.html

## iPSK vs EasyPSK

### iPSK

Based on Cisco's WPA3 SAE iPSK and private PSK documentation:

- iPSK uses MAC filtering in the WLAN workflow and depends on AAA / RADIUS policy integration for per-client or per-group key delivery.
- Cisco documents WPA3 SAE iPSK support, including WPA3-specific configuration and 6 GHz related WPA3/SAE behavior.
- Cisco's configuration and verification examples also show iPSK / private PSK operation with centrally authenticated FlexConnect scenarios.
- Operationally, iPSK is the more future-proof approach when WPA3, WPA3 SAE, or 6 GHz readiness matters.

### EasyPSK

Based on Cisco's EasyPSK documentation:

- EasyPSK also uses MAC filtering and AAA authorization in the WLAN workflow.
- Cisco documents EasyPSK as WPA2-only. The EasyPSK deployment guide explicitly states that the feature is not supported with WPA3.
- Since 6 GHz requires WPA3/SAE, EasyPSK is not a fit for Wi‑Fi 6E / 6 GHz deployments.
- Cisco's configuration guide lists EasyPSK limitations such as Local Mode, Central Authentication, and Central Switching only, which is materially narrower than newer iPSK/WPA3 options.

### Security tradeoff

EasyPSK is operationally weaker than per-device keying in environments where one passphrase is shared by a group:

- if the shared passphrase leaks, every device using that PSK should be rotated
- this creates an operational and security burden that reduces the practical value of group-shared secrets

For that reason, even though this project demonstrates that Cisco EasyPSK can be made to work with FreeRADIUS, it should be treated as a compatibility and testing solution, not as a preferred long-term security design.
