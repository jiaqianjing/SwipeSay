// Runs inside the Safari page when SwipeSay 翻译 is picked from the share sheet.
// Hands the extension the selected text plus the paragraph around it, which the model uses as context.
var ExtensionPreprocessingJS = {
    run: function (args) {
        var selection = window.getSelection ? window.getSelection() : null;
        var text = selection ? selection.toString() : "";
        var context = "";
        if (selection && selection.rangeCount > 0 && text.trim().length > 0) {
            var node = selection.getRangeAt(0).commonAncestorContainer;
            if (node && node.nodeType !== 1) { node = node.parentElement; }
            var blocks = /^(P|LI|TD|TH|DD|DT|BLOCKQUOTE|ARTICLE|SECTION|H[1-6]|PRE|FIGCAPTION)$/;
            var block = node;
            while (block && block !== document.body && !blocks.test(block.tagName)) { block = block.parentElement; }
            if (!block || block === document.body) { block = node; }
            context = (block && block.innerText) ? block.innerText : "";
            if (context.length > 1500) {
                var at = context.indexOf(text);
                var start = Math.max(0, (at < 0 ? 0 : at) - 600);
                context = context.substr(start, 1500);
            }
        }
        args.completionFunction({
            "selection": text,
            "context": context,
            "title": document.title || "",
            "url": document.URL || ""
        });
    },
    finalize: function (args) {}
};
