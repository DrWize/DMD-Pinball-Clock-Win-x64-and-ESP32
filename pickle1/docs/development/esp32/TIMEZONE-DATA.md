# ESP32 timezone data

The web remote loads timezone choices from eight regional JSON files through
`GET /api/timezones?region=...`. Each entry has an IANA representative name for
display and a POSIX `TZ` value for ESP-IDF/newlib.

The 90 names are from IANA `zonenow.tab`, release 2026c. That file intentionally
groups locations whose clocks agree now and are predicted to agree in the
future. POSIX approximations were sourced from `nayarsystems/posix_tz_db` on
2026-08-11 and checked against the IANA 2026c release notes. Alberta's new
permanent UTC-06 rule is reflected in `america.json`.

Morocco's announced move from UTC+01 to permanent UTC+00 on 2026-09-20 is a
one-time future transition that a recurring POSIX rule cannot represent exactly.
`africa.json` therefore retains the correct pre-transition UTC+01 value and must
be changed to `GMT0` for firmware released after that date.

Sources:

- <https://data.iana.org/time-zones/tzdb/zonenow.tab>
- <https://www.iana.org/time-zones/releases/2026c>
- <https://github.com/nayarsystems/posix_tz_db>

Timezone laws change. Review all three sources when updating the embedded data,
keep the eight IANA region names stable, and verify that every POSIX value fits
the firmware's 63-character persisted-timezone limit.
