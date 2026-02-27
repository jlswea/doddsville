from config import CONFIG_FILE, save_config
from formatting import BOLD, GREEN, RED, RESET, YELLOW
from paperless import check_paperless_connection


def handle_config(args, config):
    """Handle the 'config' command."""
    if args.config_action == "show":
        print(f"{BOLD}Configuration:{RESET}")
        print(f"  Config file: {CONFIG_FILE}")
        for key, value in config.items():
            if key == "paperless_token":
                print(f"  {key}: (configured)")
            else:
                print(f"  {key}: {value}")
        env_hint = []
        if "paperless_url" not in config:
            env_hint.append("DV_PAPERLESS_URL")
        if "paperless_token" not in config:
            env_hint.append("DV_PAPERLESS_TOKEN")
        if env_hint:
            print(f"\n  {YELLOW}Not set: {', '.join(env_hint)}{RESET}")
            print(f"  Set via environment variables (e.g. direnv)")
    elif args.config_action == "set":
        secret_keys = {"paperless_url", "paperless_token"}
        if args.key in secret_keys:
            env_var = f"DV_{args.key.upper()}"
            print(f"{YELLOW}{args.key} should be set via environment variable {env_var}{RESET}")
            print(f"  export {env_var}={args.value}")
            return
        config[args.key] = args.value
        save_config(config)
        print(f"{GREEN}Set {args.key}={args.value}{RESET}")
    elif args.config_action == "check":
        print(f"{BOLD}Checking paperless-ngx connection...{RESET}\n")
        success, message, details = check_paperless_connection(config)

        # Show config status
        url_status = (
            f"{GREEN}✓{RESET}"
            if details.get("url_configured")
            else f"{RED}✗{RESET}"
        )
        token_status = (
            f"{GREEN}✓{RESET}"
            if details.get("token_configured")
            else f"{RED}✗{RESET}"
        )
        print(
            f"  {url_status} paperless_url: {config.get('paperless_url', '(not set)')}"
        )
        print(
            f"  {token_status} paperless_token: {'(configured)' if details.get('token_configured') else '(not set)'}"
        )

        # Show connection result
        if success:
            print(f"\n  {GREEN}✓ {message}{RESET}")
            if "response_time_ms" in details:
                print(f"    Response time: {details['response_time_ms']}ms")
            if "document_count" in details:
                print(f"    Documents in paperless: {details['document_count']}")
        else:
            print(f"\n  {RED}✗ {message}{RESET}")
            if not details.get("url_configured"):
                print(
                    f"\n  Set env: export DV_PAPERLESS_URL=http://your-server:8000"
                )
            if not details.get("token_configured"):
                print(f"  Set env: export DV_PAPERLESS_TOKEN=your-api-token")
