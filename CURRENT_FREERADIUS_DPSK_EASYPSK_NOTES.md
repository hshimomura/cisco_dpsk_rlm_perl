# Current notes on DPSK / EasyPSK implementation in FreeRADIUS 3.2.x

This note is written as a companion comment to FreeRADIUS pull request:

- `rlm_dpsk: add generic reply attributes and optional VLAN replies`
- PR [#5830](https://github.com/FreeRADIUS/freeradius-server/pull/5830)

It summarizes what was learned while testing the policy-driven approach around:
- Ruckus DPSK
- Meraki EasyPSK
- IOS XE EasyPSK
- FreeRADIUS 3.2.x with `rlm_dpsk`

The goal is to document what worked in practice, what needed local policy, and what still looks like a better fit for later implementation in C.

## Main lessons learned

### 1. `rlm_dpsk` should stay vendor-neutral

The cleanest split is:
- vendor-specific request normalization before `rlm_dpsk`
- generic key matching inside `rlm_dpsk`
- vendor-specific reply formatting in policy

That keeps `rlm_dpsk` reusable across Ruckus DPSK, Meraki EasyPSK, and IOS XE EasyPSK.

### 2. Exposing reply attributes is what makes local policy practical

The useful reply attributes are:
- `reply:Pairwise-Master-Key`
- `reply:PSK-Identity`
- `reply:Pre-Shared-Key`

This matters because local policy can then build vendor-specific reply attributes without forcing those reply formats into the module.

### 3. Optional VLAN assignment belongs in generic reply attributes

The useful CSV format is:

```text
identity,psk[,mac[,vlanid]]
```

If `vlanid` is present, `rlm_dpsk` returns standard tunnel reply attributes:
- `Tunnel-Type = VLAN`
- `Tunnel-Medium-Type = IEEE-802`
- `Tunnel-Private-Group-Id = "<vlanid>"`

That is cleaner than hard-coding vendor-specific VLAN reply formats inside the module.

### 4. IOS XE EasyPSK request parsing is the awkward part

IOS XE EasyPSK carries required request data in `Cisco-AVPair`, including binary payloads.

The hard part is not the DPSK matching logic itself. The hard part is safely decoding:
- `cisco-anonce`
- `cisco-8021x-data`
- `cisco-bssid`
- `cisco-wlan-ssid`

In FreeRADIUS 3.2.x, a small `rlm_perl` helper works well enough for lab validation. For a cleaner upstream path, this normalization should eventually move into `rlm_preprocess` in C.

### 5. IOS XE EasyPSK reply formatting does not need to live in Perl

Once `reply:Pre-Shared-Key` is exposed, IOS XE EasyPSK reply formatting can be done in policy:

```text
update reply {
	&Cisco-AVPair += "psk=%{reply:Pre-Shared-Key}"
	&Cisco-AVPair += "psk-mode=ascii"
}
```

That is simpler than having Perl generate the final reply.

### 6. `rlm_perl` is good for exploration, but probably not the final upstream home

`rlm_perl` was useful to prove:
- which IOS XE EasyPSK fields are required
- how Cisco escaped AVPairs should be decoded
- which generic attributes must be populated before `rlm_dpsk`

But for maintainability and robustness, the better long-term home for IOS XE EasyPSK request normalization is a C implementation in a preprocessing layer.

## What was missing in FreeRADIUS 3.2.7

At the FreeRADIUS 3.2.7 stage, the policy-driven design was not complete enough for this workflow.

The practical problems found during testing were:
- `rlm_dpsk` did not expose enough generic reply state for local policy to format vendor-specific replies cleanly
- in particular, using `update reply` in policy for all of the needed vendor-specific reply paths was not practical without exposing `Pairwise-Master-Key`, `PSK-Identity`, and `Pre-Shared-Key` in a consistent way
- optional VLAN assignment from the CSV source was not available as a generic reply path

In short, at the 3.2.7 point it was not possible to finish the whole design cleanly by updating reply attributes only in local policy.

That is why the changes proposed in PR #5830 are important: they make the local-policy approach practical instead of forcing more vendor-specific logic into Perl or into the module itself.

## Recommended configuration items

### Module configuration

Example `mods-available/dpsk`:

```text
dpsk {
	ruckus = no
	cache_size = 1024
	cache_lifetime = 86400
	filename = /etc/freeradius/mods-config/dpsk/psk.csv
}
```

Example `mods-available/cisco_easy_psk_perl`:

```text
perl cisco_easy_psk_perl {
	filename = /etc/freeradius/mods-config/perl/cisco_easy_psk_perl.pl
	func_authorize = authorize
}
```

### Client settings

If the vendor sends `Message-Authenticator`, require it.

For example, when Ruckus DPSK requests already send it, the client should be configured with:

```text
require_message_authenticator = yes
```

If a device does not send it, that should be handled as a separate interoperability decision and scoped only to that client.

### `psk.csv`

Useful examples:

```text
00220022,00220022
vlan2065,00330033,,2065
00550055,00550055,a0d36578f384
00660066,00660066,f44ee3989fe0
```

Notes:
- `identity,psk` works
- `identity,psk,mac` works
- `identity,psk,,2065` works
- `identity,psk,mac,2065` works
- MAC entries must be 12 hex characters

## Sample `policy.d/dpsk`

```text
ruckus_dpsk {
	if (&Ruckus-SSID && &Ruckus-BSSID && (&Ruckus-DPSK-Cipher == 4) && &Ruckus-DPSK-Anonce && &Ruckus-DPSK-EAPOL-Key-Frame) {
		update request {
			&Called-Station-SSID := &Ruckus-SSID
			&Called-Station-MAC := &Ruckus-BSSID
			&FreeRADIUS-802.1X-Anonce := &Ruckus-DPSK-Anonce
			&FreeRADIUS-802.1X-EAPoL-Key-Msg := &Ruckus-DPSK-EAPOL-Key-Frame
		}
		updated
	}
	else {
		noop
	}
}

ruckus_dpsk_reply {
	if (&Ruckus-SSID && &reply:Pairwise-Master-Key) {
		update reply {
			&MS-MPPE-Recv-Key := &reply:Pairwise-Master-Key
		}
		updated
	}
	else {
		noop
	}
}

meraki_easy_psk {
	if (&Meraki-IPSK-SSID && &Meraki-IPSK-BSSID && &Meraki-IPSK-Anonce && &Meraki-IPSK-EAPOL) {
		update request {
			&Called-Station-SSID := &Meraki-IPSK-SSID
			&Called-Station-MAC := &Meraki-IPSK-BSSID
			&FreeRADIUS-802.1X-Anonce := &Meraki-IPSK-Anonce
			&FreeRADIUS-802.1X-EAPoL-Key-Msg := &Meraki-IPSK-EAPOL
		}
		updated
	}
	else {
		noop
	}
}

meraki_easy_psk_reply {
	if (&Meraki-IPSK-SSID && &reply:Pre-Shared-Key) {
		update reply {
			&Tunnel-Password := &reply:Pre-Shared-Key
		}
		updated
	}
	else {
		noop
	}
}

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

## Sample call flow in `sites-enabled/default`

A practical shape is:

```text
authorize {
	...
	rewrite_called_station_id
	ruckus_dpsk
	meraki_easy_psk
	cisco_easy_psk
	dpsk
	...
}

authenticate {
	...
	Auth-Type dpsk {
		dpsk
		if (updated) {
			ok
		}
	}
	...
}

post-auth {
	...
	ruckus_dpsk_reply
	meraki_easy_psk_reply
	cisco_easy_psk_reply
	...
}
```

## Notes by vendor

### Ruckus DPSK

What worked well:
- request normalization in policy
- reply formatting from `reply:Pairwise-Master-Key`

Observed reply pattern:
- `MS-MPPE-Recv-Key := &reply:Pairwise-Master-Key`

### Meraki EasyPSK

What worked well:
- request normalization in policy
- reply formatting from `reply:Pre-Shared-Key`
- optional VLAN tunnel reply attributes can coexist with Meraki-specific reply attributes

Observed reply pattern:
- `Tunnel-Password := &reply:Pre-Shared-Key`

### IOS XE EasyPSK

What worked well:
- request normalization in Perl
- reply formatting in policy
- optional VLAN tunnel reply attributes from the updated `rlm_dpsk`

Observed request-side requirements:
- decode escaped `Cisco-AVPair`
- extract `cisco-anonce`
- extract `cisco-8021x-data`
- override `Called-Station-MAC` with `cisco-bssid`
- keep `Called-Station-SSID` aligned with `cisco-wlan-ssid`

Observed reply pattern:
- `Cisco-AVPair += "psk=%{reply:Pre-Shared-Key}"`
- `Cisco-AVPair += "psk-mode=ascii"`

## What should likely happen next in FreeRADIUS itself

If this work were carried further upstream, the next logical step would be:
- keep `rlm_dpsk` generic
- keep vendor reply formatting in policy
- move IOS XE EasyPSK request normalization from Perl into `rlm_preprocess` in C

That would preserve the working architecture discovered here while avoiding a Perl dependency for Cisco request parsing.


## Observed connection logs

The following points were confirmed from live `radiusd -X` traces during interoperability testing.

### Ruckus DPSK

Observed request normalization:
- `Ruckus-SSID := dpsk`
- `Ruckus-BSSID := 0xa80bfb747330`
- `FreeRADIUS-802.1X-Anonce` populated from `Ruckus-DPSK-Anonce`
- `FreeRADIUS-802.1X-EAPoL-Key-Msg` populated from `Ruckus-DPSK-EAPOL-Key-Frame`

Observed module path:
- `dpsk: Found FreeRADIUS-802.1X-EAPoL-Key-Msg.  Setting 'Auth-Type  = dpsk'`
- `dpsk: Creating &reply:Pairwise-Master-Key`
- `dpsk: Creating &reply:PSK-Identity and &reply:Pre-Shared-Key`

Observed reply path:
- `ruckus_dpsk_reply` updated the reply
- `MS-MPPE-Recv-Key := &reply:Pairwise-Master-Key`
- final result was `Access-Accept`

### Meraki EasyPSK

Observed request normalization:
- `Meraki-IPSK-SSID := EasyPSK`
- `Meraki-IPSK-BSSID := 0xce6e3a601c50`
- `FreeRADIUS-802.1X-Anonce` populated from `Meraki-IPSK-Anonce`
- `FreeRADIUS-802.1X-EAPoL-Key-Msg` populated from `Meraki-IPSK-EAPOL`

Observed module path:
- `dpsk: Found FreeRADIUS-802.1X-EAPoL-Key-Msg.  Setting 'Auth-Type  = dpsk'`
- `dpsk: Creating &reply:Pairwise-Master-Key`
- `dpsk: Creating &reply:PSK-Identity and &reply:Pre-Shared-Key`
- `dpsk: Creating VLAN reply attributes for VLAN 2065`

Observed reply path:
- `meraki_easy_psk_reply` updated the reply
- `Tunnel-Password := &reply:Pre-Shared-Key`
- final reply included:
  - `Tunnel-Type = VLAN`
  - `Tunnel-Medium-Type = IEEE-802`
  - `Tunnel-Private-Group-Id = "2065"`
  - `Tunnel-Password = <<< secret >>>`
- final result was `Access-Accept`

### IOS XE EasyPSK

Observed request normalization in Perl:
- `Cisco-AVPair` was decoded
- `cisco-anonce` extracted and written to `FreeRADIUS-802.1X-Anonce`
- `cisco-8021x-data` extracted and written to `FreeRADIUS-802.1X-EAPoL-Key-Msg`
- `cisco-bssid` overrode `Called-Station-MAC`
- `cisco-wlan-ssid` aligned `Called-Station-SSID`

Observed module path:
- `cisco_easy_psk_perl` returned `updated`
- `dpsk: Found FreeRADIUS-802.1X-EAPoL-Key-Msg.  Setting 'Auth-Type  = dpsk'`
- `dpsk: Creating &reply:Pairwise-Master-Key`
- `dpsk: Creating &reply:PSK-Identity and &reply:Pre-Shared-Key`
- `dpsk: Creating VLAN reply attributes for VLAN 2065`

Observed reply path:
- `cisco_easy_psk_reply` updated the reply
- `Cisco-AVPair += "psk=%{reply:Pre-Shared-Key}"`
- `Cisco-AVPair += "psk-mode=ascii"`
- final reply included:
  - `Tunnel-Type = VLAN`
  - `Tunnel-Medium-Type = IEEE-802`
  - `Tunnel-Private-Group-Id = "2065"`
  - `Cisco-AVPair = "psk=00330033"`
  - `Cisco-AVPair = "psk-mode=ascii"`
- final result was `Access-Accept`
