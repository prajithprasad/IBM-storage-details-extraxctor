# IBM Storage Details Extractor

Parses IBM storage device XML config logs and generates a detailed Excel report — VDisk/LUN ID mappings, host mappings, replication (Remote Copy) data, FlashCopy mappings, and more.

## How It Works

1. **Collect the log** — On the IBM storage device, run the `SVC_Snap` command to collect a support snapshot.
2. **Extract the config file** — From the collected snap, extract the file named `svc.config.cron.xml`.
3. **Run the script** — Copy `svc.config.cron.xml` into the same folder as `ptool.pl`, then run the tool from the command line (see Usage below).
4. **Output** — The script parses the XML and generates an Excel workbook with multiple sheets, including:
   - Cluster info
   - Nodes
   - Storage Pools (mdiskgrp)
   - VDisks (with LUN IDs, host mappings)
   - MDisks
   - Hosts / Host-to-VDisk mappings
   - Controllers
   - FlashCopy groups & mappings
   - Remote Copy groups & mappings (replication)
   - FC & Ethernet port info
  


## Requirements

- Perl 5
- Perl modules:
  - `Archive::Tar`
  - `DateTime::Format::Strptime`
  - `Excel::Writer::XLSX`
  - `XML::Parser`
  - `Getopt::Long`
  - `Time::Piece`
  - (core modules: `File::Basename`, `POSIX`, `Data::Dumper`, `Cwd`, `English`)

Install missing modules via CPAN, e.g.:
```bash
cpan Excel::Writer::XLSX XML::Parser DateTime::Format::Strptime Archive::Tar
```

> **Note:** `ptool.pl` loads its companion module from a file named `ptool.pm` (from the script's directory, or an `IBM/` subfolder).

## Usage

Place `svc.config.cron.xml` in the same folder as `ptool.pl`, then run:

```bash
perl ptool.pl --xml svc.config.cron.xml
```

Other supported options:

| Option              | Description                                        |
|---------------------|-----------------------------------------------------|
| `--xml <file>`       | Path to the `svc.config.cron.xml` config file       |
| `--svcout <file>`    | Path to an svcout file                              |
| `--lsfabric <file>`  | Path to an lsfabric file                            |
| `--audit <file>`     | Path to an audit log file                           |
| `--errlog <file>`    | Path to an error log file                           |
| `--outdir <dir>`     | Output directory for the generated Excel file       |
| `--auto` / `--noauto`| Auto-detect input files in the current directory (on by default) |
| `--1920`             | Enable processing for 1920-series systems           |

If run with no arguments, the script auto-scans the current directory for matching files (e.g. any file starting with `svc.config`).

## Notes

- Config settings for sheet names, columns, and formatting are defined in `Ptool_v4.ini` — update this if you need to add/remove columns or sheets.
- Ensure any sample XML files committed to this repo have sensitive data (hostnames, serials, IPs) removed before making the repo public.
