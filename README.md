📱 FFmpeg Scripts for Termux on Android

Hi there! 👋
I'm not a coder, just someone who tinkers and likes to automate things a bit.
These scripts were made using AI tools like Claude, ChatGPT, DeepSeek, and a lot of trial and error on Android + Termux.
I found them helpful, so I'm sharing them here in case they help someone else too. Feel free to edit, improve, or remix them as you like! 😊


---

🧰 What’s Inside?

A collection of FFmpeg-based scripts you can run in Termux on Android to:

Compress videos 📉

Convert formats 🎥➡️🎞️

Trimming ✂️

Merging 🔀



---

⚙️ How to Set It Up (Beginner Friendly)

1. 📲 Install Termux on Android

[Download Termux from F-Droid](https://f-droid.org/en/packages/com.termux/)

> Note: Don’t use the Play Store version — it's outdated!



2. ⬇️ Install Required Packages

Once inside Termux, paste and run:

```pkg update && pkg upgrade```
```pkg install ffmpeg unzip git```

3. 📦 Download This Repository

You can either:

Download as ZIP from GitHub and unzip inside Termux, or

Clone with git:


```git clone https://github.com/AARENKAY/ffmpeg-termux-scripts.git```

```cd ffmpeg-termux-scripts```

4. 🛠️ Make Scripts Executable

Run this to give execution permission to all scripts:

chmod +x *.sh

5. 🚀 Run a Script

For example, to convert a video:

```./convert.sh```


---

📝 Notes

These scripts are designed to be as simple and modifiable as possible.

Don’t hesitate to open the .sh files and change things to fit your needs.

If you improve anything or fix bugs, feel free to contribute or let me know!



---

📫 Feedback or Issues?

You can open an issue or just fork and tweak things on your own.


---

📜 License

MIT License — do whatever you like, just don’t sue me 😄
