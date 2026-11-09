package com.example.taskwand

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import androidx.core.content.ContextCompat
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray

/** Provides the row views for the task widget's ListView. */
class TaskWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        TaskWidgetFactory(applicationContext)
}

private class TaskWidgetFactory(private val context: Context) :
    RemoteViewsService.RemoteViewsFactory {

    private var items: JSONArray = JSONArray()

    override fun onCreate() {}

    override fun onDataSetChanged() {
        // Re-read the JSON the Flutter side saved on every refresh.
        val raw = HomeWidgetPlugin.getData(context).getString("tw_tasks", "[]") ?: "[]"
        items = try {
            JSONArray(raw)
        } catch (_: Exception) {
            JSONArray()
        }
    }

    override fun onDestroy() {
        items = JSONArray()
    }

    override fun getCount(): Int = items.length()

    override fun getViewAt(position: Int): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.task_widget_item)
        val obj = items.optJSONObject(position)
        if (obj != null) {
            views.setTextViewText(R.id.twi_desc, obj.optString("d"))
            views.setTextViewText(R.id.twi_due, obj.optString("l"))
            val colorRes = if (obj.optBoolean("o")) R.color.widget_overdue else R.color.widget_subtext
            views.setTextColor(R.id.twi_due, ContextCompat.getColor(context, colorRes))
        }
        // Empty fill-in intent -> the provider's template opens the app.
        views.setOnClickFillInIntent(R.id.twi_root, Intent())
        return views
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long = position.toLong()

    override fun hasStableIds(): Boolean = false
}
