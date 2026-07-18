use anyhow::{anyhow, Result};
use taskchampion::{
    storage::AccessMode, Operations, Replica, ServerConfig, SqliteStorage, Status, Uuid,
    utc_timestamp,
};
use tokio::sync::Mutex;

static REPLICA: Mutex<Option<Replica<SqliteStorage>>> = Mutex::const_new(None);

pub struct TaskSummary {
    pub uuid: String,
    pub description: String,
    pub project: Option<String>,
    pub due_unix: Option<i64>,
    /// "pending" or "completed". Deleted/recurring/unknown tasks are never returned.
    pub status: String,
    /// Completion time (Unix seconds), from taskchampion's "end" property. Set when a
    /// task is completed, cleared when it returns to pending. `None` for pending tasks.
    pub end_unix: Option<i64>,
}

fn status_str(status: &Status) -> &'static str {
    match status {
        Status::Pending => "pending",
        Status::Completed => "completed",
        Status::Deleted => "deleted",
        Status::Recurring => "recurring",
        Status::Unknown(_) => "unknown",
    }
}

pub async fn open_replica(dir: String) -> Result<()> {
    let storage = SqliteStorage::new(dir, AccessMode::ReadWrite, true).await?;
    let mut guard = REPLICA.lock().await;
    *guard = Some(Replica::new(storage));
    Ok(())
}

/// List tasks that have NOT been deleted. When `include_completed` is false, only
/// pending tasks are returned; when true, completed tasks are included as well.
/// Deleted, recurring, and unknown-status tasks are always excluded.
pub async fn list_tasks(include_completed: bool) -> Result<Vec<TaskSummary>> {
    let mut guard = REPLICA.lock().await;
    let replica = guard.as_mut().ok_or_else(|| anyhow!("replica not open"))?;
    let tasks = replica.all_tasks().await?;
    let mut out: Vec<TaskSummary> = tasks
        .into_values()
        .filter(|t| match t.get_status() {
            Status::Pending => true,
            Status::Completed => include_completed,
            _ => false,
        })
        .map(|t| TaskSummary {
            uuid: t.get_uuid().to_string(),
            description: t.get_description().to_string(),
            project: t.get_value("project").map(|s| s.to_string()),
            due_unix: t.get_due().map(|dt| dt.timestamp()),
            status: status_str(&t.get_status()).to_string(),
            end_unix: t.get_timestamp("end").map(|dt| dt.timestamp()),
        })
        .collect();
    // Pending before completed; within each group, due-dated first (soonest first),
    // then undated alphabetically.
    out.sort_by(|a, b| {
        let pa = a.status == "pending";
        let pb = b.status == "pending";
        pb.cmp(&pa).then_with(|| match (a.due_unix, b.due_unix) {
            (Some(x), Some(y)) => x.cmp(&y),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => a.description.cmp(&b.description),
        })
    });
    Ok(out)
}

pub async fn add_task(
    description: String,
    project: Option<String>,
    due_unix: Option<i64>,
    due_time_minutes: Option<i32>,
) -> Result<()> {
    let mut guard = REPLICA.lock().await;
    let replica = guard.as_mut().ok_or_else(|| anyhow!("replica not open"))?;
    let mut ops = Operations::new();
    let uuid = Uuid::new_v4();
    let mut task = replica.create_task(uuid, &mut ops).await?;
    task.set_description(description, &mut ops)?;
    task.set_status(Status::Pending, &mut ops)?;
    task.set_entry(
        Some(utc_timestamp(taskchampion::chrono::Utc::now().timestamp())),
        &mut ops,
    )?;
    apply_project(&mut task, project, &mut ops)?;
    task.set_due(due_timestamp(due_unix, due_time_minutes), &mut ops)?;
    replica.commit_operations(ops).await?;
    Ok(())
}

/// Edit an existing task's description, project, and due date. A `None` project or
/// due date clears that field; `Some` sets it.
pub async fn modify_task(
    uuid: String,
    description: String,
    project: Option<String>,
    due_unix: Option<i64>,
    due_time_minutes: Option<i32>,
) -> Result<()> {
    let mut guard = REPLICA.lock().await;
    let replica = guard.as_mut().ok_or_else(|| anyhow!("replica not open"))?;
    let uuid = Uuid::parse_str(&uuid)?;
    let mut task = replica
        .get_task(uuid)
        .await?
        .ok_or_else(|| anyhow!("no such task"))?;
    let mut ops = Operations::new();
    task.set_description(description, &mut ops)?;
    apply_project(&mut task, project, &mut ops)?;
    task.set_due(due_timestamp(due_unix, due_time_minutes), &mut ops)?;
    replica.commit_operations(ops).await?;
    Ok(())
}

/// Combine a due date (`due_unix`, midnight of the day) with a time-of-day given
/// as minutes past midnight (`due_time_minutes`). When a date is set but no time
/// is supplied, the due time defaults to 23:59 (end of day). A `None` date clears
/// the due entirely, regardless of the time.
fn due_timestamp(
    due_unix: Option<i64>,
    due_time_minutes: Option<i32>,
) -> Option<taskchampion::chrono::DateTime<taskchampion::chrono::Utc>> {
    // 23:59 (end of day) when no explicit time is provided.
    const DEFAULT_DUE_MINUTES: i32 = 23 * 60 + 59;
    due_unix.map(|date| {
        let minutes = due_time_minutes.unwrap_or(DEFAULT_DUE_MINUTES);
        utc_timestamp(date + minutes as i64 * 60)
    })
}

fn apply_project(
    task: &mut taskchampion::Task,
    project: Option<String>,
    ops: &mut Operations,
) -> Result<()> {
    // Treat an empty/whitespace-only project as "no project".
    let project = project.filter(|p| !p.trim().is_empty());
    task.set_value("project", project, ops)?;
    Ok(())
}

pub async fn complete_task(uuid: String) -> Result<()> {
    let mut guard = REPLICA.lock().await;
    let replica = guard.as_mut().ok_or_else(|| anyhow!("replica not open"))?;
    let uuid = Uuid::parse_str(&uuid)?;
    let mut task = replica
        .get_task(uuid)
        .await?
        .ok_or_else(|| anyhow!("no such task"))?;
    let mut ops = Operations::new();
    task.done(&mut ops)?;
    replica.commit_operations(ops).await?;
    Ok(())
}

/// Move a completed task back to pending.
pub async fn uncomplete_task(uuid: String) -> Result<()> {
    let mut guard = REPLICA.lock().await;
    let replica = guard.as_mut().ok_or_else(|| anyhow!("replica not open"))?;
    let uuid = Uuid::parse_str(&uuid)?;
    let mut task = replica
        .get_task(uuid)
        .await?
        .ok_or_else(|| anyhow!("no such task"))?;
    let mut ops = Operations::new();
    task.set_status(Status::Pending, &mut ops)?;
    replica.commit_operations(ops).await?;
    Ok(())
}

pub async fn delete_task(uuid: String) -> Result<()> {
    let mut guard = REPLICA.lock().await;
    let replica = guard.as_mut().ok_or_else(|| anyhow!("replica not open"))?;
    let uuid = Uuid::parse_str(&uuid)?;
    let mut task = replica
        .get_task(uuid)
        .await?
        .ok_or_else(|| anyhow!("no such task"))?;
    let mut ops = Operations::new();
    task.set_status(Status::Deleted, &mut ops)?;
    replica.commit_operations(ops).await?;
    Ok(())
}

// taskchampion's `dyn Server` (and its sync future) are not `Send`, but FRB's
// wrap_async requires the returned future to be `Send`. Run the whole sync on a
// dedicated blocking-pool thread with its own single-threaded runtime so the
// non-Send future never has to cross threads.
pub async fn sync_tasks(url: String, client_id: String, secret: String) -> Result<()> {
    tokio::task::spawn_blocking(move || {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        rt.block_on(async move {
            let mut guard = REPLICA.lock().await;
            let replica = guard.as_mut().ok_or_else(|| anyhow!("replica not open"))?;
            let config = ServerConfig::Remote {
                url,
                client_id: Uuid::parse_str(&client_id)?,
                encryption_secret: secret.into_bytes(),
            };
            let mut server = config.into_server().await?;
            // avoid_snapshots = true: taskchampion recommends this on devices more
            // constrained than a desktop (a phone), producing snapshots only when the
            // server marks it urgent. sync() already rebuilds the working set, so no
            // explicit rebuild_working_set call is needed afterward.
            replica.sync(&mut server, true).await?;
            Ok::<(), anyhow::Error>(())
        })
    })
    .await?
}

#[cfg(test)]
mod tests {
    use super::*;

    // The bridge functions operate on a single global REPLICA, so this test drives the
    // whole CRUD lifecycle sequentially against a fresh temp SQLite replica. It verifies
    // the local (offline) behavior only; sync needs a live taskchampion-sync-server.
    #[tokio::test]
    async fn crud_lifecycle() {
        let dir = tempfile::tempdir().unwrap();
        open_replica(dir.path().to_str().unwrap().to_string())
            .await
            .unwrap();

        // Empty to start.
        assert!(list_tasks(false).await.unwrap().is_empty());

        // Add two tasks, one with a project and due date.
        add_task("buy chalk".into(), None, None, None).await.unwrap();
        // Date at midnight with no explicit time defaults to 23:59 (86340s later).
        add_task(
            "write report".into(),
            Some("work".into()),
            Some(1_000_000),
            None,
        )
        .await
        .unwrap();

        let pending = list_tasks(false).await.unwrap();
        assert_eq!(pending.len(), 2);
        // Due-dated task sorts before the undated one.
        assert_eq!(pending[0].description, "write report");
        assert_eq!(pending[0].project.as_deref(), Some("work"));
        assert_eq!(pending[0].due_unix, Some(1_000_000 + 86340));
        assert_eq!(pending[0].status, "pending");
        assert_eq!(pending[1].description, "buy chalk");
        assert_eq!(pending[1].project, None);

        // Modify: change description, add a project, clear the due date.
        let uuid = pending[0].uuid.clone();
        modify_task(uuid.clone(), "write final report".into(), Some("ops".into()), None, None)
            .await
            .unwrap();
        let after = list_tasks(false).await.unwrap();
        let modified = after.iter().find(|t| t.uuid == uuid).unwrap();
        assert_eq!(modified.description, "write final report");
        assert_eq!(modified.project.as_deref(), Some("ops"));
        assert_eq!(modified.due_unix, None);

        // Clearing a project via an empty string removes it.
        modify_task(uuid.clone(), "write final report".into(), Some("  ".into()), None, None)
            .await
            .unwrap();
        let after = list_tasks(false).await.unwrap();
        assert_eq!(
            after.iter().find(|t| t.uuid == uuid).unwrap().project,
            None
        );

        // Complete one task: it drops out of the pending list but appears when completed
        // tasks are included.
        complete_task(uuid.clone()).await.unwrap();
        assert_eq!(list_tasks(false).await.unwrap().len(), 1);
        let with_done = list_tasks(true).await.unwrap();
        assert_eq!(with_done.len(), 2);
        let done = with_done.iter().find(|t| t.uuid == uuid).unwrap();
        assert_eq!(done.status, "completed");
        // Pending tasks sort before completed ones.
        assert_eq!(with_done[0].status, "pending");
        assert_eq!(with_done[1].status, "completed");

        // Uncomplete restores it to pending.
        uncomplete_task(uuid.clone()).await.unwrap();
        assert_eq!(list_tasks(false).await.unwrap().len(), 2);

        // Delete removes it from every non-deleted view.
        delete_task(uuid.clone()).await.unwrap();
        assert_eq!(list_tasks(true).await.unwrap().len(), 1);
        assert!(list_tasks(true)
            .await
            .unwrap()
            .iter()
            .all(|t| t.uuid != uuid));
    }
}
