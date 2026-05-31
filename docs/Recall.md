# Recall — answer from your history

Recall lets you ask the browser about pages you've already read, in plain English —
like *"that transformers article I read last week?"* — and get the page back, with
an answer. It's like a search box for your own memory.

Everything happens **on your Mac**. The pages you read are saved and searched
locally, in a file you own. Nothing is uploaded to do this.

## How to use it

There are two ways:

**1. The recall bar — press ⇧⌘Y**
A search bar pops up. Start typing what you remember and matching pages show up
instantly. You can:
- Use the arrow keys to move, **Enter** to open, **⌘Enter** to open in the background.
- Type time words like *"last week"* or *"yesterday"* — it understands them.
- Type a site like *"on stripe.com"* to only look there.
- Click the ⭐ on a result to mark it important so it ranks higher next time.

**2. Just ask the AI**
In the chat panel, ask things like *"what was that article about attention I read
recently?"* The AI looks through your history, answers, and links the pages it used.
If it can't find a good match, it tells you so instead of making something up.

## What it can do

- **Remembers what pages actually said**, not just their titles. So you can search by
  what an article was *about*, even if you don't remember the exact words in the title.
- **Two ways to match:** by keywords (exact words) and by meaning (so "attention
  mechanism" can find an article that only said "transformers"). It blends both.
- **Understands time and place:** "last week", "in March", "yesterday", "on nytimes.com".
- **Ranks by what mattered to you:** a page you read for a while, came back to, or
  starred shows up above one you barely glanced at — even if both match your words.
- **Suggests related pages:** open the recall bar while on a page and it shows other
  things you've read about the same topic.

## What it remembers (and what it doesn't)

- It only saves pages you **actually spend time reading** (a few seconds on screen).
  Pages you click into and immediately leave aren't saved.
- It **never** saves:
  - Pages showing a password box (logins, checkout pages).
  - Sites on your block list (banking, email, and similar are blocked by default).
  - PDFs and your home/new-tab page.
- When you clear your browsing history — a single entry, a whole site, a date range,
  or everything — the saved page content is deleted right along with it.

## Privacy

This is the whole point of doing it this way:

- The saved content and the search both live **only on your Mac**, in
  `~/.thebrowser/recall.sqlite`. You can delete that file anytime.
- When you ask the **AI** a question, only the few matching snippets it needs are sent
  to the AI model — and you can see exactly which ones. Your full history is never sent.
- Want zero data to leave your Mac? Turn on **"Answer on-device"** in Settings. Then
  the recall bar writes the answer itself, locally, with no AI model involved at all.

## Settings

Open **Settings → General → Recall** to:

- Turn the whole feature on or off.
- Turn meaning-based (semantic) search on or off.
- Turn on **on-device answers** for fully private answering.
- Change how long you must look at a page before it's saved.
- Edit the list of sites that are never saved.
- See how big the index is, and clear it with one click (your history stays).

The recall bar shortcut (⇧⌘Y) can be changed in **Settings → Keybindings**.
