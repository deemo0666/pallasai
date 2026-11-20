import CryptoKit
import Foundation

enum OfflineReplay {
    static func page(title: String, turns: [LocalTurn]) throws -> Data {
        let file = try ReplayDocument.encode(title: title, turns: turns)
        return try page(title: title, file: file)
    }

    static func page(title: String, file: Data) throws -> Data {
        let document = try ReplayDocument.decode(file)
        let schedule = ReplayTiming(events: document.events)
        let entries: [Object] = zip(document.events, schedule.rows).map { event, span in
            ["label": event.label, "text": event.text, "detail": event.detail, "start": span.start, "answer": span.answer,
             "end": span.end, "stream": event.kind == "reply", "images": event.imageIDs]
        }
        let words = ["image": String(localized: "对话图片"), "details": String(localized: "详情"), "replay": String(localized: "重新播放"),
                     "pause": String(localized: "暂停"), "play": String(localized: "播放")]
        let payload = try JSONSerialization.data(withJSONObject: ["title": title, "events": entries, "end": schedule.duration, "words": words])
        func embedded(_ bytes: Data) -> String {
            String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
                .replacingOccurrences(of: ">", with: "\\u003e").replacingOccurrences(of: "&", with: "\\u0026")
        }
        let script = """
        const el = id => document.getElementById(id);
        const doc = JSON.parse(el('timeline').textContent);
        const assets = JSON.parse(el('app-data').textContent).assets || {};
        const list = el('messages'), bar = el('position'), play = el('play'), speed = el('speed');
        document.title = el('title').textContent = doc.title;
        bar.max = Math.max(doc.end, 0.001);
        let clock = 0, previous = 0, running = true, rate = 1, frame;
        const rows = doc.events.map(e => {
          const article = document.createElement('article'), label = document.createElement('strong'), body = document.createElement('p');
          label.textContent = e.label;
          article.append(label, body);
          for (const id of e.images) {
            const asset = assets[id];
            if (!asset) continue;
            const image = document.createElement('img');
            image.alt = doc.words.image; image.src = 'data:' + asset.type + ';base64,' + asset.data;
            article.append(image);
          }
          if (e.detail) {
            const details = document.createElement('details'), summary = document.createElement('summary'), content = document.createElement('p');
            summary.textContent = doc.words.details; content.textContent = e.detail;
            details.append(summary, content); article.append(details);
          }
          list.append(article);
          return {article, body, event:e};
        });
        function render() {
          bar.value = clock;
          play.textContent = clock >= doc.end ? doc.words.replay : running ? doc.words.pause : doc.words.play;
          for (const {article,body,event:e} of rows) {
            article.hidden = e.start > clock;
            if (article.hidden) continue;
            const ratio = (clock - e.answer) / Math.max(0.001, e.end - e.answer);
            const text = e.stream && clock < e.end ? Array.from(e.text).slice(0, Math.max(0, Math.floor(Array.from(e.text).length * ratio))).join('') + '▍' : e.text;
            if (body.textContent !== text) body.textContent = text;
          }
        }
        function tick(now) {
          if (previous) clock = Math.min(doc.end, clock + (now - previous) * rate / 1000);
          previous = now;
          if (clock >= doc.end) running = false;
          render();
          if (running) frame = requestAnimationFrame(tick);
        }
        function restart() {
          cancelAnimationFrame(frame); previous = 0; render();
          if (running) frame = requestAnimationFrame(tick);
        }
        play.onclick = () => {
          if (clock >= doc.end) {clock = 0; running = true;} else running = !running;
          restart();
        };
        bar.oninput = () => {clock = Number(bar.value); running = false; restart();};
        speed.onclick = () => {rate = rate === 4 ? 1 : rate * 2; speed.textContent = rate + '×';};
        el('all').onclick = () => {clock = doc.end; running = false; restart();};
        restart();
        """
        let hash = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
        let html = """
        <!doctype html><html lang="\(Bundle.main.preferredLocalizations.first ?? "zh-Hans")"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; script-src 'sha256-\(hash)'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <title>\(String(localized: "对话回放"))</title><style>:root{color-scheme:light dark}body{font:1rem system-ui;max-width:44rem;margin:auto;padding:1rem}nav{position:sticky;top:0;background:Canvas;padding:.7rem 0;display:flex;gap:.5rem}input{flex:1;min-width:3rem}p{white-space:pre-wrap;overflow-wrap:anywhere}article img{max-width:100%;height:auto}article{border-bottom:1px solid GrayText;padding:1rem 0}</style>
        <h1 id="title"></h1><nav><button id="play">\(words["pause"]!)</button><input type="range" id="position" aria-label="\(String(localized: "进度"))" step=".01" min="0"><button id="speed">1×</button><button id="all">\(String(localized: "全文"))</button></nav><main id="messages"></main>
        <script type="application/json" id="app-data">\(embedded(file))</script><script type="application/json" id="timeline">\(embedded(payload))</script><script>\(script)</script></html>
        """
        let data = Data(html.utf8)
        guard data.count <= ReplayDocument.fileLimit else { throw HostError(String(localized: "网页超过 4 MB。少选几条消息，或关掉图片。")) }
        return data
    }
}
