#!/usr/bin/env python3
"""Adds one release to SwipeSay's Sparkle appcast (creating the file if needed).

Keeps the newest MAX_ITEMS entries. Called by scripts/release.sh.
"""
import argparse
import email.utils
import html
import os
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC = "http://purl.org/dc/elements/1.1/"
MAX_ITEMS = 10
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", DC)


def parse_ed_attrs(text):
    """`sparkle:edSignature="…" length="123"` → (signature, length)."""
    sig = re.search(r'sparkle:edSignature="([^"]+)"', text)
    length = re.search(r'length="(\d+)"', text)
    if not sig or not length:
        sys.exit(f"cannot parse sign_update output: {text!r}")
    return sig.group(1), length.group(1)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("appcast")
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--min-macos", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--ed-attrs", required=True)
    p.add_argument("--notes-html", required=True)
    a = p.parse_args()

    if os.path.exists(a.appcast):
        tree = ET.parse(a.appcast)
        rss = tree.getroot()
        channel = rss.find("channel")
    else:
        rss = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = "SwipeSay"
        ET.SubElement(channel, "link").text = "https://github.com/jiaqianjing/SwipeSay"
        ET.SubElement(channel, "description").text = "SwipeSay updates"
        ET.SubElement(channel, "language").text = "zh-CN"
        tree = ET.ElementTree(rss)

    # Replace an existing entry for the same build, if the release is being redone.
    for old in channel.findall("item"):
        if old.findtext(f"{{{SPARKLE}}}version") == a.build:
            channel.remove(old)

    sig, length = parse_ed_attrs(a.ed_attrs)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"SwipeSay {a.version}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = a.build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = a.version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = a.min_macos
    ET.SubElement(item, "description").text = open(a.notes_html, encoding="utf-8").read()
    ET.SubElement(item, "enclosure", {
        "url": a.url,
        "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": sig,
        "length": length,
    })

    # Newest first, right after the channel metadata.
    items = channel.findall("item")
    first = list(channel).index(items[0]) if items else len(channel)
    channel.insert(first, item)
    for extra in channel.findall("item")[MAX_ITEMS:]:
        channel.remove(extra)

    ET.indent(tree, space="  ")
    xml = ET.tostring(rss, encoding="unicode")
    # Release notes are HTML: wrap them in CDATA so they stay readable in the feed.
    xml = re.sub(r"<description>(.*?)</description>",
                 lambda m: "<description><![CDATA[" + html.unescape(m.group(1)) + "]]></description>",
                 xml, flags=re.S)
    with open(a.appcast, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n' + xml + "\n")


if __name__ == "__main__":
    main()
