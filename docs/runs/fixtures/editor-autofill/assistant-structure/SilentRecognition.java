package dev.magina.autofillobserver;

import android.content.Intent;
import android.os.RemoteException;
import android.speech.RecognitionService;
import android.speech.SpeechRecognizer;
import android.util.Log;

/** Voice-service metadata requires a recognizer. This fixture opens no audio input. */
public final class SilentRecognition extends RecognitionService {
    @Override protected void onStartListening(Intent intent, Callback callback) {
        Log.e(AssistService.TAG, "unexpected_recognition");
        try { callback.error(SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS); }
        catch (RemoteException ignored) {}
    }
    @Override protected void onCancel(Callback callback) {}
    @Override protected void onStopListening(Callback callback) {}
}
