package dev.magina.autofillobserver;

import android.os.SystemClock;
import android.service.autofill.FillCallback;
import android.service.autofill.FillRequest;
import android.service.autofill.FillResponse;
import android.service.autofill.SaveInfo;
import android.util.Log;
import android.util.Size;
import android.view.inputmethod.InlineSuggestionsRequest;
import android.widget.inline.InlinePresentationSpec;
import java.util.Collections;

final class RetainedReply {
    static void deliver(FillRequest request, int stage, FillCallback callback) {
        if (stage != 1 && stage != 2) {
            callback.onSuccess(null);
            return;
        }
        // No dataset, saveable field, authentication intent, or fill UI.
        int flags = SaveInfo.FLAG_DELAY_SAVE | SaveInfo.FLAG_DONT_SAVE_ON_FINISH;
        SaveInfo delayed = new SaveInfo.Builder(SaveInfo.SAVE_DATA_TYPE_GENERIC).setFlags(flags).build();
        FillResponse response = new FillResponse.Builder().setSaveInfo(delayed).build();
        Log.i("RetainedReply", "reply stage=" + stage + " request=" + request.getId()
            + " inline=" + (request.getInlineSuggestionsRequest() != null)
            + " requestedFlags=" + flags + " uptime=" + SystemClock.uptimeMillis());
        callback.onSuccess(response);
    }

    static InlineSuggestionsRequest inlineRequest() {
        InlinePresentationSpec spec = new InlinePresentationSpec.Builder(
            new Size(1, 1), new Size(100, 40)).build();
        Log.i("RetainedReply", "ime_created_inline uptime=" + SystemClock.uptimeMillis());
        return new InlineSuggestionsRequest.Builder(Collections.singletonList(spec))
            .setMaxSuggestionCount(1).build();
    }
}
