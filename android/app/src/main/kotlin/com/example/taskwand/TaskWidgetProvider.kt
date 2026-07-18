package com.example.taskwand

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Home-screen widget listing pending, due-dated tasks (soonest first). The rows
 * come from a collection adapter backed by [TaskWidgetService], which reads the
 * JSON the Flutter side saved via home_widget. Tapping the header or any row
 * opens the app.
 */
class TaskWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.task_widget)

            // Bind the scrollable list to the RemoteViewsService. A unique data URI
            // per widget id keeps multiple placed widgets from sharing an adapter.
            val serviceIntent = Intent(context, TaskWidgetService::class.java).apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
            }
            views.setRemoteAdapter(R.id.tw_list, serviceIntent)
            views.setEmptyView(R.id.tw_list, R.id.tw_empty)

            // Header taps open the app.
            val openApp = HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java)
            views.setOnClickPendingIntent(R.id.tw_header, openApp)

            // Template so row taps also open the app (rows supply an empty fill-in).
            val templateIntent = Intent(context, MainActivity::class.java).apply {
                action = HomeWidgetLaunchIntent.HOME_WIDGET_LAUNCH_ACTION
            }
            val templatePending = PendingIntent.getActivity(
                context,
                0,
                templateIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setPendingIntentTemplate(R.id.tw_list, templatePending)

            appWidgetManager.updateAppWidget(id, views)
            appWidgetManager.notifyAppWidgetViewDataChanged(id, R.id.tw_list)
        }
    }
}
