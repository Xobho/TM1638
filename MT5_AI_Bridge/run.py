#!/usr/bin/env python3
"""Entry point for the MT5 AI bridge.

Usage:
    python run.py                  # run forever, polling for new bars
    python run.py --once           # one analysis pass per configured symbol, then exit
    python run.py --config my.yaml # use a config file other than config.yaml
"""

import argparse

from mt5_ai_bridge.agent import Agent
from mt5_ai_bridge.config import Config


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.yaml")
    parser.add_argument("--once", action="store_true", help="run a single pass and exit")
    args = parser.parse_args()

    config = Config.load(args.config)
    agent = Agent(config)

    if args.once:
        agent.run_once()
    else:
        agent.run_forever()


if __name__ == "__main__":
    main()
