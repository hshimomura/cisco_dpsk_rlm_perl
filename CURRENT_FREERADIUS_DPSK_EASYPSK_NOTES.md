# Current notes on DPSK / EasyPSK implementation in FreeRADIUS 3.2.x

This note separates two related but different topics:

- what PR [#5830](https://github.com/FreeRADIUS/freeradius-server/pull/5830) changes in generic `rlm_dpsk`
- what is still needed locally to interoperate with IOS XE EasyPSK on FreeRADIUS 3.2.x

The intent is to keep the upstream-facing part vendor-neutral, while documenting the IOS XE-specific request normalization and policy that were required during lab validation.

## PR #5830: generic `rlm_dpsk` changes

PR #5830 is about making `rlm_dpsk` more useful as a generic backend for multiple vendor workflows.

The working split is:
- vendor-specific request normalization before `rlm_dpsk`
- generic PSK / PMK matching inside `rlm_dpsk`
- vendor-specific reply formatting in local policy

That split worked in practice for:
- Ruckus DPSK
- Meraki EasyPSK
- IOS XE EasyPSK

### Why the PR matters

The practical gaps found in older 3.2.x builds were:
- `rlm_dpsk` did not expose enough generic reply state for local policy
- vendor-specific reply formatting was awkward without stable reply attributes
- optional VLAN assignment from `psk.csv` was not available as a generic reply path

The useful generic reply attributes are:
- `reply:Pairwise-Master-Key`
- `reply:PSK-Identity`
- `reply:Pre-Shared-Key`

The useful CSV format is:

```text
identity,psk[,mac[,vlanid]]
```

If `vlanid` is present, `rlm_dpsk` can return standard tunnel reply attributes:
- `Tunnel-Type = VLAN`
- `Tunnel-Medium-Type = IEEE-802`
- `Tunnel-Private-Group-Id = "<vlanid>"`

That keeps VLAN handling generic and avoids pushing vendor reply formats into the module.

### What this enables in local policy

With those reply attributes exposed, local policy can build vendor-specific replies without modifying `rlm_dpsk` again.

Examples:
- Ruckus DPSK: `MS-MPPE-Recv-Key := &reply:Pairwise-Master-Key`
- Meraki EasyPSK: `Tunnel-Password := &reply:Pre-Shared-Key`
- IOS XE EasyPSK: `Cisco-AVPair += "psk=%{reply:Pre-Shared-Key}"`

## IOS XE EasyPSK on FreeRADIUS 3.2.x

### Why Perl is needed

IOS XE EasyPSK is awkward on FreeRADIUS 3.2.x because the required request-side data arrives in `Cisco-AVPair`, including escaped binary payloads.

The hard part is not DPSK matching itself. The hard part is safely extracting and decoding:
- `cisco-anonce`
- `cisco-8021x-data`
- `cisco-bssid`
- `cisco-wlan-ssid`

In FreeRADIUS 3.2.x, doing that reliably in `unlang` alone is difficult because:
- `Cisco-AVPair` may contain binary data
- request classification based on `Cisco-AVPair[*]` can be tripped by NUL bytes
- the escaped AVPair values need binary-safe decoding before they can be copied into generic attributes

For lab validation, a small `rlm_perl` helper is a practical answer. It lets FreeRADIUS normalize the Cisco request into the same generic attributes that `rlm_dpsk` already understands.

### What the Perl helper does

The Perl helper is used only for request normalization.

It extracts Cisco-specific values from `Cisco-AVPair` and populates generic request attributes:
- `cisco-anonce` -> `FreeRADIUS-802.1X-Anonce`
- `cisco-8021x-data` -> `FreeRADIUS-802.1X-EAPoL-Key-Msg`
- `cisco-bssid` -> `Called-Station-MAC`
- `cisco-wlan-ssid` -> `Called-Station-SSID`

That leaves `rlm_dpsk` itself vendor-neutral.

### Why the final reply should stay in policy

Once `reply:Pre-Shared-Key` is available, IOS XE reply formatting does not need to live in Perl.

A simple policy block is enough:

```text
update reply {
	&Cisco-AVPair += "psk=%{reply:Pre-Shared-Key}"
	&Cisco-AVPair += "psk-mode=ascii"
}
```

This is simpler to maintain than generating the final Cisco reply directly in Perl.

### Recommended configuration items for IOS XE

#### Module configuration

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

#### `psk.csv`

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

#### Sample `policy.d/dpsk`

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

#### Sample call flow in `sites-enabled/default`

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

### Observed IOS XE behavior

During live `radiusd -X` testing, the IOS XE path that worked was:
- `cisco_easy_psk_perl` decoded `Cisco-AVPair`
- `FreeRADIUS-802.1X-Anonce` was populated from `cisco-anonce`
- `FreeRADIUS-802.1X-EAPoL-Key-Msg` was populated from `cisco-8021x-data`
- `Called-Station-MAC` was overridden with `cisco-bssid`
- `Called-Station-SSID` was aligned with `cisco-wlan-ssid`
- `rlm_dpsk` produced `reply:Pairwise-Master-Key`, `reply:PSK-Identity`, and `reply:Pre-Shared-Key`
- local policy added `Cisco-AVPair = "psk=..."` and `Cisco-AVPair = "psk-mode=ascii"`
- optional VLAN tunnel attributes were also returned when configured in `psk.csv`

### Longer-term direction

`rlm_perl` is a good exploration and interoperability tool, but probably not the best final upstream home for IOS XE request parsing.

The cleaner long-term direction still looks like:
- keep `rlm_dpsk` generic
- keep vendor-specific reply formatting in policy
- move IOS XE EasyPSK request normalization into a C preprocessing layer with binary-safe Cisco AVPair handling

That preserves the working architecture discovered here while avoiding a Perl dependency for Cisco request parsing.
