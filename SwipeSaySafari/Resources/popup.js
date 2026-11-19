// Toolbar popup: how a selection on the page triggers SwipeSay. Read by content.js via browser.storage.
const inputs = Array.from(document.querySelectorAll('input[name="trigger"]'));
browser.storage.local.get("trigger").then((v) => {
    const value = (v && v.trigger) || "auto";
    for (const input of inputs) input.checked = input.value === value;
});
for (const input of inputs) {
    input.addEventListener("change", () => {
        if (input.checked) browser.storage.local.set({ trigger: input.value });
    });
}
document.getElementById("open-app").addEventListener("click", (event) => {
    event.preventDefault();
    browser.tabs.update({ url: "swipesay://settings" }).catch(() => {});
    window.close();
});
