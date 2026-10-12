# Changelog

## 1.10.0 - 2026-10-09

First public release of Transport Sizer.

- Size Exchange Edge and Mailbox transport servers from measured reference profiles or customer calibration, without Excel.
- WPF interface, technical HTML report, customer summary, JSON scenarios, traffic import and calibration scripts.
- Manufacturer disk specifications and reference-backed generic classes shared with Mailbox Sizer, including source URLs and check dates.
- Separate system and queue disks, automatic capacities and measured IOPS overrides. Adapt physical IOPS to transport transfer sizes instead of assuming 32 KB mailbox database pages.
- Protected RAID with write penalties and rebuild margins; explicit warnings for unknown disk performance, wide RAID-5 and queue SSD endurance.
- Anonymized reference profiles and examples; no private development history, laboratory identifiers or generated customer reports.
