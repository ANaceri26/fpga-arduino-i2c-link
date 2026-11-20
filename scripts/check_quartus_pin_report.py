"""Validate QSF targets and, optionally, the physical pins in a Quartus .pin report.
Run after compilation: python scripts/check_quartus_pin_report.py PATH_TO.pin
No third-party Python dependencies. This does not run a simulation.
"""
import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_QSF = ROOT / 'board/arduino_i2c/de10_arduino_i2c.qsf'

def read_assignments(path):
    locations, standards = {}, {}
    for number, line in enumerate(path.read_text(encoding='utf-8-sig').splitlines(), 1):
        if line.startswith(('set_location_assignment ', 'set_instance_assignment ')) and ' -to ' in line:
            target = line.split(' -to ', 1)[1].strip()
            if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*(?:\[\d+\])?', target):
                raise ValueError(f'{path}:{number}: use a bare QSF port name, not {target!r}')
            if line.startswith('set_location_assignment '):
                match = re.fullmatch(r'set_location_assignment PIN_(\w+) -to (\S+)', line)
                if not match:
                    raise ValueError(f'Unexpected location syntax on line {number}')
                pin, name = match.groups()
                if name in locations:
                    raise ValueError(f'Duplicate location assignment for {name}')
                locations[name] = pin
            match = re.fullmatch(r'set_instance_assignment -name IO_STANDARD "([^"]+)" -to (\S+)', line)
            if match:
                standard, name = match.groups()
                standards[name] = standard
    if len(locations) != 72 or len(set(locations.values())) != 72:
        raise ValueError('Expected 72 unique port/pin assignments')
    if set(locations) != set(standards):
        raise ValueError('Every assigned port must have an IO_STANDARD')
    return locations, standards

def normal_standard(value):
    return value.upper().replace(' ', '').replace('-', '')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pin_report', type=Path, nargs='?')
    parser.add_argument('--qsf', type=Path, default=DEFAULT_QSF)
    args = parser.parse_args()
    try:
        locations, standards = read_assignments(args.qsf)
    except (OSError, ValueError) as error:
        print(f'FAIL: {error}')
        return 1
    print('PASS: QSF has 72 unique bare port names, locations and I/O standards.')
    if args.pin_report is None:
        print('No fitted .pin report supplied: Quartus acceptance/placement is NOT verified.')
        return 0
    actual = {}
    for line in args.pin_report.read_text(errors='replace').splitlines():
        fields = [field.strip() for field in line.split(':')]
        if len(fields) >= 4 and fields[0] in locations:
            actual[fields[0]] = (fields[1], fields[3])
    errors = []
    for name, pin in locations.items():
        if name not in actual:
            errors.append(f'{name}: missing from .pin report')
            continue
        actual_pin, standard = actual[name]
        if actual_pin != pin:
            errors.append(f'{name}: expected {pin}, fitted {actual_pin}')
        if normal_standard(standard) != normal_standard(standards[name]):
            errors.append(f'{name}: expected {standards[name]}, fitted {standard}')
    if errors:
        print(f'FAIL: {len(errors)} fitted pin/voltage mismatches.')
        for error in errors:
            print('  ' + error)
        return 1
    print('PASS: all 72 fitted pins and I/O standards match the project.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
