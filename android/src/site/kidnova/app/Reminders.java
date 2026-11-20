package site.kidnova.app;

import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Build;

import org.json.JSONArray;
import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.List;
import java.util.Locale;

/**
 * Attendance reminders, worked out on the phone (no internet needed when they fire).
 * The web page tells the app, through KidnovaApp.setAttendance(...), which registers are
 * still missing today and when the term runs. At the reminder times (default 08:30, and a
 * follow-up at 13:00) the app shows a notification only when a register is still missing.
 */
public final class Reminders extends BroadcastReceiver {
    static final String PREFS = "kidnova_reminders";
    static final String CHANNEL = "attendance";
    static final String ACTION_FIRE = "site.kidnova.app.REMINDER";
    private static final int NOTIFY_ID = 1001;

    @Override
    public void onReceive(Context ctx, Intent intent) {
        String a = intent.getAction();
        if (ACTION_FIRE.equals(a)) {
            try { maybeNotify(ctx); } catch (Exception ignored) { }
        }
        schedule(ctx); // after a reminder, a phone restart or an app update: plan the next one
    }

    static SharedPreferences prefs(Context ctx) {
        return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    static boolean enabled(Context ctx) { return prefs(ctx).getBoolean("on", true); }
    static String morning(Context ctx) { return prefs(ctx).getString("morning", "08:30"); }
    static String followUp(Context ctx) { return prefs(ctx).getString("followup", "13:00"); }

    static String today() {
        return new SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Calendar.getInstance().getTime());
    }

    private static int[] hm(String t) {
        try {
            String[] p = t.split(":");
            return new int[]{Math.max(0, Math.min(23, Integer.parseInt(p[0].trim()))), Math.max(0, Math.min(59, Integer.parseInt(p[1].trim())))};
        } catch (Exception e) {
            return new int[]{8, 30};
        }
    }

    /** Plan the next reminder (the earliest coming reminder time). */
    static void schedule(Context ctx) {
        AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        PendingIntent pi = PendingIntent.getBroadcast(ctx, 0, new Intent(ctx, Reminders.class).setAction(ACTION_FIRE),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        am.cancel(pi);
        if (!enabled(ctx) || !prefs(ctx).getBoolean("teacher", false)) return;
        long now = System.currentTimeMillis(), best = Long.MAX_VALUE;
        List<String> times = new ArrayList<>();
        times.add(morning(ctx));
        if (!followUp(ctx).isEmpty()) times.add(followUp(ctx));
        for (String t : times) {
            int[] x = hm(t);
            Calendar c = Calendar.getInstance();
            c.set(Calendar.HOUR_OF_DAY, x[0]); c.set(Calendar.MINUTE, x[1]); c.set(Calendar.SECOND, 0); c.set(Calendar.MILLISECOND, 0);
            if (c.getTimeInMillis() <= now + 30000) c.add(Calendar.DAY_OF_MONTH, 1);
            best = Math.min(best, c.getTimeInMillis());
        }
        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, best, pi);
    }

    /** Show the reminder if today is a school day in term and a register is still missing. */
    static void maybeNotify(Context ctx) throws Exception {
        if (!enabled(ctx)) return;
        Calendar now = Calendar.getInstance();
        int dow = now.get(Calendar.DAY_OF_WEEK);
        if (dow == Calendar.SATURDAY || dow == Calendar.SUNDAY) return;
        String raw = prefs(ctx).getString("state", "");
        if (raw.isEmpty()) return;
        JSONObject st = new JSONObject(raw);
        if (!st.optBoolean("attendance", true)) return;
        String today = today();
        String open = st.optString("termOpen", ""), close = st.optString("termClose", "");
        if (open.isEmpty() || close.isEmpty() || today.compareTo(open) < 0 || today.compareTo(close) > 0) return;
        JSONArray holidays = st.optJSONArray("holidays");
        if (holidays != null) for (int i = 0; i < holidays.length(); i++) if (today.equals(holidays.optString(i))) return;

        List<String> missing = new ArrayList<>();
        if (today.equals(st.optString("date"))) {
            JSONArray m = st.optJSONArray("missing");
            if (m != null) for (int i = 0; i < m.length(); i++) missing.add(m.optString(i));
        } else {
            // The app was not opened today yet: remind for all of the teacher's classes.
            JSONArray c = st.optJSONArray("classes");
            if (c != null) for (int i = 0; i < c.length(); i++) missing.add(c.optString(i));
        }
        if (missing.isEmpty()) return;
        String list = join(missing);
        String title = missing.size() == 1 ? "Take attendance · " + list : "Take attendance for " + missing.size() + " classes";
        String text = (missing.size() == 1 ? "The register for " + list + " is not saved yet today." : list + " — registers not saved yet today.")
                + " Tap to record it now.";
        notify(ctx, title, text);
    }

    private static String join(List<String> xs) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < xs.size(); i++) { if (i > 0) b.append(i == xs.size() - 1 ? " and " : ", "); b.append(xs.get(i)); }
        return b.toString();
    }

    static void ensureChannel(Context ctx) {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
            NotificationChannel ch = new NotificationChannel(CHANNEL, "Attendance reminders", NotificationManager.IMPORTANCE_HIGH);
            ch.setDescription("Reminds you to take the register when it is not saved yet.");
            nm.createNotificationChannel(ch);
        }
    }

    static void notify(Context ctx, String title, String text) {
        ensureChannel(ctx);
        Intent open = new Intent(ctx, MainActivity.class)
                .setAction(Intent.ACTION_VIEW)
                .setData(Uri.parse("https://kidnova.site/#tattend"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent pi = PendingIntent.getActivity(ctx, 1, open, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder nb = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(ctx, CHANNEL) : new Notification.Builder(ctx);
        nb.setSmallIcon(R.drawable.ic_notify)
                .setColor(0xFF0B6CB5)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(new Notification.BigTextStyle().bigText(text))
                .setContentIntent(pi)
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_REMINDER);
        if (Build.VERSION.SDK_INT < 26) nb.setPriority(Notification.PRIORITY_HIGH).setDefaults(Notification.DEFAULT_ALL);
        try {
            ((NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE)).notify(NOTIFY_ID, nb.build());
        } catch (SecurityException ignored) { /* notifications not allowed */ }
    }

    static void clear(Context ctx) {
        ((NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE)).cancel(NOTIFY_ID);
    }
}
