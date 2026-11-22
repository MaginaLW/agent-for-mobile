package dev.magina.autofillobserver;

import static dev.magina.autofillobserver.HostAndroid.*;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.IdentityHashMap;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/** 场景真值在宿主。观察器的入口只取得 FillRequest、取消状态与回调。 */
public final class WindowReplay {
    private static final ComponentName TARGET = new ComponentName(ProbeIme.TARGET, ProbeIme.TARGET + ".TargetActivity");
    private static final IdentityHashMap<AssistStructure, Activity> producers = new IdentityHashMap<>();
    private static Path scratch;

    private static final class Field implements InputConnection {
        final int id, localX;
        int probes;
        Field(int id, int localX) { this.id = id; this.localX = localX; }
        public void requestTextBoundsInfo(RectF area, java.util.concurrent.Executor executor,
                                          java.util.function.Consumer<Object> callback) {
            require(area.equals(new RectF(-3, -3, -3, -3)), "unexpected IME probe");
            probes++;
            executor.execute(() -> callback.accept(null));
        }
        ViewNode node(boolean focused, int session) {
            return new ViewNode(localX, 32, 200, 70, new AutofillId(id, session), focused, List.of());
        }
    }

    private static final class Activity {
        final String instance;
        final int screenX, width;
        final Field left, right;
        Activity(String instance, int screenX, int width, int firstId, boolean overlap) {
            this.instance = instance; this.screenX = screenX; this.width = width;
            left = new Field(firstId, 40);
            right = new Field(firstId + 1, overlap ? 40 : width - 240);
        }
        FillContext capture(boolean focusedRight, long acquired) {
            return capture(focusedRight, acquired, 7);
        }
        FillContext capture(boolean focusedRight, long acquired, int session) {
            var root = new ViewNode(0, 0, width, 1080, null, false,
                    List.of(left.node(!focusedRight, session), right.node(focusedRight, session)));
            var tree = new AssistStructure(TARGET, List.of(new WindowNode(screenX, root)), acquired, acquired + 1);
            producers.put(tree, this); // 只供宿主做身份参照。两个树各有独立的对象。
            var trigger = new AutofillId((focusedRight ? right : left).id, session);
            return new FillContext(tree, trigger, 5);
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static void connect(Activity active, boolean right, long started) {
        active.left.probes = active.right.probes = 0; // 靶在每个阶段重新计数，两控件保持原实例。
        var field = right ? active.right : active.left;
        var ime = new ProbeIme();
        ime.editor = new EditorInfo(TARGET.pkg(), new AutofillId(field.id, 0));
        ime.connection = field;
        HostAndroid.clock = started;
        ime.onStartInput(ime.editor, false);
        require(field.probes == 1 && ProbeIme.active.current(), "current input probe did not arrive");
    }

    private static JSONObject consume(String name, Activity active, FillContext context, int stage, long received)
            throws Exception {
        var dir = Files.createDirectory(scratch.resolve(name));
        HostAndroid.filesDir = dir.toFile();
        if (stage != 0) Files.writeString(dir.resolve("natural-stage"), String.valueOf(stage));
        HostAndroid.clock = received;
        var request = new FillRequest(List.of(context), context.getRequestId(),
                stage == 0 ? FillRequest.FLAG_MANUAL_REQUEST : 0);
        int[] emptyResponses = {0};
        new ProbeAutofillService().onFillRequest(request, new CancellationSignal(false), response -> {
            require(response == null, "unexpected fill response");
            emptyResponses[0]++;
        });
        require(emptyResponses[0] == 1, "callback count");
        var file = dir.resolve(stage == 0 ? "result.json" : "natural-" + stage + ".json");
        var receipt = new JSONObject(Files.readString(file));
        if (stage != 0) {
            require(receipt.getInt("callback_count") == 1 && receipt.getInt("terminal_count") == 1, "terminal count");
            receipt = receipt.getJSONArray("samples").getJSONObject(0);
        }
        var source = producers.get(context.getStructure());
        require(source != null && active.left.probes + active.right.probes == 1, "missing host witness");
        var probed = active.right.probes == 1 ? active.right : active.left;
        int x = active.screenX + probed.localX;
        System.out.println(new JSONObject().put("case", name).put("host_active", active.instance)
                .put("host_source", source.instance).put("host_probe", active.right.probes == 1 ? "RIGHT" : "LEFT")
                .put("host_layout_bounds", new JSONArray(List.of(x, 32, x + 200, 102)))
                .put("observer_reason", receipt.getString("reason")).put("observer_side", receipt.get("selected_side"))
                .put("observer_bounds", receipt.get("selected_bounds")).put("editors", receipt.get("editor_count")));
        return receipt;
    }

    private static void check(JSONObject receipt, String reason, int editors, String side, String bounds) {
        require(reason.equals(receipt.getString("reason")), "reason " + receipt);
        require(receipt.getInt("editor_count") == editors, "editor count " + receipt);
        if (side == null) {
            require(receipt.isNull("selected_side") && receipt.isNull("selected_bounds"), "selection " + receipt);
        } else {
            require(side.equals(receipt.getString("selected_side"))
                    && new JSONArray(bounds).similar(receipt.getJSONArray("selected_bounds")), "selection " + receipt);
        }
    }

    public static void main(String[] args) throws Exception {
        scratch = Path.of(args[0]);
        var single = new Activity("single", 0, 2340, 11, false);
        connect(single, true, 100);
        check(consume("single-right", single, single.capture(true, 118), 0, 125),
                "MATCH", 2, "RIGHT", "[2100,32,2300,102]");

        // 同一输入连接与时钟快照，替换来源实例；宿主独立保存探针和结构拥有者。
        var active = new Activity("active-right", 1200, 1200, 11, false);
        var other = new Activity("other", 1200, 1200, 11, false);
        connect(active, true, 200);
        var correctContext = active.capture(true, 218, 7);
        var wrongContext = other.capture(true, 218, 13);
        int correctSession = correctContext.getFocusedId().session();
        int wrongSession = wrongContext.getFocusedId().session();
        require(correctSession != wrongSession, "two source windows should have separate fill sessions");
        for (var context : List.of(correctContext, wrongContext)) {
            var fields = context.getStructure().getWindowNodeAt(0).root.children();
            require(fields.size() == 2 && fields.stream().allMatch(
                    field -> field.getAutofillId().session() == context.getFocusedId().session()),
                    "each tree must share the session of its own fill trigger");
        }
        require(producers.get(correctContext.getStructure()) == active
                && producers.get(wrongContext.getStructure()) != active
                && other.left.probes == 0 && other.right.probes == 0, "source or connection invariant");
        var correct = consume("correct-window", active, correctContext, 2, 225);
        var wrong = consume("wrong-window", active, wrongContext, 2, 225);
        check(correct, "MATCH", 2, "RIGHT", "[2160,32,2360,102]");
        check(wrong, "MATCH", 2, "RIGHT", "[2160,32,2360,102]");
        require(correct.similar(wrong), "observer receipts should be indistinguishable for this pair");
        System.out.println(new JSONObject().put("pair", List.of("correct-window", "wrong-window"))
                .put("host_fill_sessions", List.of(correctSession, wrongSession))
                .put("equal_terminal_receipts", true).put("window_acceptance", "BLOCKED")
                .put("attributed_side_in_either_case", JSONObject.NULL)
                .put("attributed_bounds_in_either_case", JSONObject.NULL));

        var distinct = new Activity("other-disjoint-ids", 1200, 1200, 81, false);
        check(consume("wrong-distinct-ids", active, distinct.capture(true, 218), 2, 225),
                "NO_ID_MATCH", 2, null, null);
        var overlap = new Activity("single-overlap", 0, 2340, 11, true);
        connect(overlap, false, 300);
        check(consume("overlap", overlap, overlap.capture(false, 318), 0, 325),
                "INDISTINGUISHABLE_BOUNDS", 2, null, null);
        var conflict = new Activity("single-conflict", 0, 2340, 11, false);
        connect(conflict, false, 400);
        check(consume("focus-conflict", conflict, conflict.capture(true, 418), 0, 425),
                "FOCUS_DISAGREES", 2, null, null);

        var old = new Activity("same-activity", 0, 2340, 11, false);
        connect(old, false, 500);
        var oldContext = old.capture(false, 518);
        check(consume("previous-left", old, oldContext, 1, 525), "MATCH", 2, "LEFT", "[40,32,240,102]");
        connect(old, true, 700);
        check(consume("delayed-old-structure", old, oldContext, 2, 725), "STALE_STRUCTURE", 2, null, null);

        var excluded = new Activity("excluded", 0, 2340, 11, false);
        connect(excluded, false, 900);
        var excludedContext = excluded.capture(false, 918);
        var refusal = consume("optout", excluded, excludedContext, 3, 925);
        check(refusal, "TARGET_OPTED_OUT", 0, null, null);
        require(excludedContext.getStructure().getWindowNodeAt(0).reads == 0
                && refusal.isNull("ime_generation") && refusal.isNull("acquisition_start_uptime_ms"),
                "excluded tree accessed");
        System.out.println("9 host cases; wrong-window falsely matched; window attribution BLOCKED");
    }
}
