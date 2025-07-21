# Agar.io-bot
The aim of the project is to create a bot that can play Agar.io

The full coding process is streamed live on http://www.twitch.tv/apostolique

Make sure to install both bot.user.js and launcher.user.js

#Honorable mention
There are other people working on bots, you can check the forks, as well as GamerLio's Github which uses genetic algorithms: https://github.com/leomwu/agario-bot

#How to Install
**Web Tutorial**

http://bot.jlynx.net/

**Videos**

Created by https://www.youtube.com/user/karter61/

https://www.youtube.com/watch?v=Zvq38nmCm1s - Install Tutorial.

https://www.youtube.com/watch?v=x2-DFRnEFBU - Android Tutorial.

#Hotkeys

* Press 'R' if you want to toggle the line and dot drawing.
* Press 'T' if you want to use the manual controls.
* Press 'D' to toggle the dark mode.
* Press 'F' to toggle the show mass option.
* Press 'ESC' for the option menu.

## Trading Bot

This repository now includes a simple Python trading bot (`trading_bot.py`).
It fetches historical data from Yahoo Finance, optimizes a moving average
crossover strategy, and outputs a basic buy or sell decision. Use

```bash
python trading_bot.py AAPL --start 2022-01-01 --end 2022-06-01 --opt
```

to run an example with parameter optimization.
