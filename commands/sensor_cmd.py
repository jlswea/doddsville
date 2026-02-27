import logging

from config import LOG_FILE, load_sensor_config
from formatting import BOLD, GREEN, RED, RESET, YELLOW
from sensors import list_sensors, run_all_sensors, run_sensor

# Max items to show inline per category before truncating
_MAX_INLINE = 15


def _setup_logging():
    """Configure file logging for sensors."""
    sensor_logger = logging.getLogger("sensors")
    if not sensor_logger.handlers:
        handler = logging.FileHandler(LOG_FILE)
        handler.setFormatter(
            logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
        )
        sensor_logger.addHandler(handler)
        sensor_logger.setLevel(logging.DEBUG)


def handle_sensor(args, conn, cur):
    """Handle the 'sensor' command."""
    if args.sensor_action == "list":
        sensors = list_sensors()
        if not sensors:
            print("No sensors registered.")
            return

        print(f"\n{BOLD}Available sensors:{RESET}\n")
        for s in sensors:
            print(f"  {GREEN}{s['name']}{RESET}")
            if s["description"]:
                print(f"    {s['description']}")
            print()

    elif args.sensor_action == "run":
        _setup_logging()
        sensor_config = load_sensor_config()
        dry_run = getattr(args, "dry_run", False)
        sensor_name = getattr(args, "sensor_name", None)

        if sensor_name:
            # Run specific sensor
            sensor_cfg = sensor_config.get(sensor_name, {})
            print(f"Running sensor: {sensor_name}...")

            try:
                result = run_sensor(sensor_name, sensor_cfg, cur)
            except ValueError as e:
                print(f"{RED}{e}{RESET}")
                return

            _print_result(result, dry_run)

            if not dry_run and not result.errors:
                conn.commit()
                print(f"\n{GREEN}Changes committed.{RESET}")
        else:
            # Run all enabled sensors
            print("Running all enabled sensors...\n")
            results = run_all_sensors(sensor_config, cur)

            if not results:
                print(f"{YELLOW}No enabled sensors found.{RESET}")
                print("Configure sensors in sensors/sensors.yaml")
                return

            for result in results:
                _print_result(result, dry_run)
                print()

            if not dry_run and not any(r.errors for r in results):
                conn.commit()
                print(f"{GREEN}All changes committed.{RESET}")
            elif dry_run:
                conn.rollback()

        print(f"\nLog: {LOG_FILE}")


def _print_result(result, dry_run: bool):
    """Print a sensor result with diff details."""
    prefix = f"{YELLOW}[DRY RUN]{RESET} " if dry_run else ""
    print(f"{prefix}{BOLD}{result.sensor_name}{RESET}: {len(result.securities)} securities found")

    if result.errors:
        for error in result.errors:
            print(f"  {RED}Error: {error}{RESET}")
        return

    stats = result.stats
    if not stats:
        return

    # Summary line
    parts = []
    if stats.get("inserted"):
        parts.append(f"{GREEN}+{stats['inserted']} new{RESET}")
    if stats.get("updated"):
        parts.append(f"{YELLOW}~{stats['updated']} updated{RESET}")
    if stats.get("unchanged"):
        parts.append(f"{stats['unchanged']} unchanged")
    if parts:
        print(f"  {', '.join(parts)}")

    # Detail: new securities
    inserted = stats.get("inserted_items", [])
    if inserted:
        print(f"\n  {GREEN}{BOLD}New:{RESET}")
        for item in inserted[:_MAX_INLINE]:
            print(f"    {GREEN}+ {item['isin']}  {item['name']}{RESET}")
        if len(inserted) > _MAX_INLINE:
            print(f"    ... and {len(inserted) - _MAX_INLINE} more (see log)")

    # Detail: updated securities
    updated = stats.get("updated_items", [])
    if updated:
        print(f"\n  {YELLOW}{BOLD}Updated:{RESET}")
        for item in updated[:_MAX_INLINE]:
            print(f"    {YELLOW}~ {item['isin']}  {item['name']}{RESET}")
            for field, (old, new) in item["changes"].items():
                old_short = (old[:40] + "...") if len(old) > 43 else old
                new_short = (new[:40] + "...") if len(new) > 43 else new
                print(f"      {field}: {RED}{old_short}{RESET} → {GREEN}{new_short}{RESET}")
        if len(updated) > _MAX_INLINE:
            print(f"    ... and {len(updated) - _MAX_INLINE} more (see log)")

    # Log full details
    logger = logging.getLogger("sensors")
    for item in inserted:
        logger.info(f"[{result.sensor_name}] NEW {item['isin']} {item['name']} ({item['type']})")
    for item in updated:
        changes_str = ", ".join(
            f"{f}: {old!r} -> {new!r}" for f, (old, new) in item["changes"].items()
        )
        logger.info(f"[{result.sensor_name}] UPD {item['isin']} {item['name']}: {changes_str}")
