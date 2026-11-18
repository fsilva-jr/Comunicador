// Alternância de tema (claro/escuro). O script inline no <head> de cada página
// já aplica a preferência salva antes da primeira pintura.
(function () {
    var KEY = "comunicador-theme";
    function get() { try { return localStorage.getItem(KEY); } catch (e) { return null; } }
    function current() {
        var s = get();
        if (s === "light" || s === "dark") return s;
        return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
    }
    function paint(btn, t) {
        btn.textContent = t === "dark" ? "☀" : "☽";
        btn.title = t === "dark" ? "Tema claro" : "Tema escuro";
    }
    document.addEventListener("DOMContentLoaded", function () {
        var btn = document.querySelector(".theme-toggle");
        if (!btn) return;
        paint(btn, current());
        btn.addEventListener("click", function () {
            var t = current() === "dark" ? "light" : "dark";
            document.documentElement.setAttribute("data-theme", t);
            try { localStorage.setItem(KEY, t); } catch (e) { }
            paint(btn, t);
        });
    });
})();
