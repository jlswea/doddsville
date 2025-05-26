import argparse


def dv_add(args):
    print(args)


def dv_ls(args):
    print(args)


commands = {"add": dv_add, "ls": dv_ls}


def main() -> None:
    parser = argparse.ArgumentParser(
        description="dv: A ledger for stock market transactions"
    )

    parser.add_argument(
        "command",
        type=str,
        choices=commands.keys(),
        nargs="?",
        help="The command to execute",
    )

    parser.add_argument(
        "-v",
        "--version",
        action="version",
        version="doddsville@0.0.1",
        help="The installed version of the doddsville CLI",
    )

    args = parser.parse_args()


if __name__ == "__main__":
    main()
