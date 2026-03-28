# Cisco EasyPSK Helper for FreeRADIUS `rlm_perl`

Perl helper module for Cisco EasyPSK on FreeRADIUS 3.2.x.

As validated for this project, Cisco Identity Services Engine (ISE) 3.5 Patch 2 did not provide the EasyPSK behavior required here, so extending FreeRADIUS was necessary.

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

Path note:

- In this repository, examples use `/usr/local/etc/raddb` because the test host was FreeBSD.
- On many Linux systems, FreeRADIUS is instead rooted at `/etc/raddb`.
- On Ubuntu packages, FreeRADIUS 3 is commonly rooted at `/etc/freeradius/3.0`.

## Installation

Install the Perl module on the FreeRADIUS host:

```text
/usr/local/etc/raddb/cisco_dpsk_rlm_perl.pl
```

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
  - `perl_dpsk`
  - `dpsk`
  - `if (ok || updated) { ... &Auth-Type := dpsk ... }`
- `authenticate {}`:
  - `Auth-Type dpsk { dpsk; if (updated || ok) { ok } }`
- `post-auth {}`:
  - `perl_dpsk`
- `Post-Auth-Type REJECT {}`:
  - `perl_dpsk`

### 1. Perl module definition

Create `mods-enabled/perl_dpsk`:

```text
perl perl_dpsk {
	filename = /usr/local/etc/raddb/cisco_dpsk_rlm_perl.pl
	func_authorize = authorize
	func_post_auth = post_auth
}
```

### 2. `authorize {}` in `sites-enabled/default`

Keep `rewrite_called_station_id`, then add `perl_dpsk`, then `dpsk`.

Highlighted additions:

```diff
 # sites-enabled/default
 authorize {
 	filter_username
 	preprocess
 	chap
 	mschap
 	digest
 
 	rewrite_called_station_id
+	# >>> Cisco EasyPSK begin
+	perl_dpsk
+	dpsk
+	if (ok || updated) {
+		update control {
+			&Auth-Type := dpsk
+		}
+	}
+	# <<< Cisco EasyPSK end
 
 	suffix
 	eap
 	files
 	sql
 	expiration
 	logintime
 	pap
 }
```

```text
authorize {
	filter_username
	preprocess
	chap
	mschap
	digest

	rewrite_called_station_id
	perl_dpsk
	dpsk
	if (ok || updated) {
		update control {
			&Auth-Type := dpsk
		}
	}

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
 	Auth-Type dpsk {
 		dpsk
+		if (updated || ok) {
+			ok
+		}
 	}
 }
```

```text
authenticate {
	Auth-Type dpsk {
		dpsk
		if (updated || ok) {
			ok
		}
	}
}
```

### 4. `post-auth {}`

Call `perl_dpsk` so successful replies get Cisco EasyPSK attributes.

Highlighted additions:

```diff
 # sites-enabled/default
 post-auth {
+	# >>> Cisco EasyPSK begin
+	perl_dpsk
+	# <<< Cisco EasyPSK end
 
 	if (&User-Name != "anonymous") {
 		sql
 	}
 	exec
 	remove_reply_message_if_eap
 }
```

```text
post-auth {
	perl_dpsk

	if (&User-Name != "anonymous") {
		sql
	}
	exec
	remove_reply_message_if_eap
}
```

### 5. `Post-Auth-Type REJECT {}`

Call `perl_dpsk` here too so reject replies get `cisco-easy-psk-error-cause`.

Highlighted additions:

```diff
 # sites-enabled/default
 Post-Auth-Type REJECT {
 	auth_log
 	sql
 	attr_filter.access_reject
 	eap
+	# >>> Cisco EasyPSK begin
+	perl_dpsk
+	# <<< Cisco EasyPSK end
 	remove_reply_message_if_eap
 }
```

```text
Post-Auth-Type REJECT {
	auth_log
	sql
	attr_filter.access_reject
	eap
	perl_dpsk
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
00440044,00440044,f4-4e-e3-98-9f-e0
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

## Notes

- `radpostauth_pkey` duplicate errors are unrelated to EasyPSK itself.
- Cisco ISE support should be rechecked for future releases, but this repository documents the behavior validated against ISE 3.5 Patch 2 at the time of writing.

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

### Practical limits of this FreeRADIUS implementation

This repository implements EasyPSK matching on the FreeRADIUS side by feeding the Cisco handshake material into `rlm_dpsk` and letting it search the candidate PSKs listed in `mods-config/dpsk/psk.csv`.

That means:

- the server effectively tries candidate PSKs until one matches the handshake
- response time grows with the size of the candidate set
- large PSK inventories are not a good fit

In other words, this repository is suitable for lab work, compatibility testing, and small controlled environments, but not as a recommendation for large-scale EasyPSK production.

### Security tradeoff

EasyPSK is operationally weaker than per-device keying in environments where one passphrase is shared by a group:

- if the shared passphrase leaks, every device using that PSK should be rotated
- this creates an operational and security burden that reduces the practical value of group-shared secrets

For that reason, even though this project demonstrates that Cisco EasyPSK can be made to work with FreeRADIUS, it should be treated as a compatibility and testing solution, not as a preferred long-term security design.
