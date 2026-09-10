use mux_proto::peer::{OpenMode, Opened, PtyInput, PtySnapshot};
use muxd::{
    manager::Manager,
    server::{handle_connection, Policy},
};
use tokio::io::DuplexStream;
mod common;
use common::{read_dump, read_output_until, read_reply, request, write_request};

#[tokio::test]
async fn v8_interactive_client_remains_compatible() {
    let manager = Manager::default();
    let (mut client, server) = tokio::io::duplex(1024 * 1024);
    let serving = manager.clone();
    tokio::spawn(async move {
        let (r, w) = tokio::io::split(server);
        let _ = handle_connection(serving, r, w, &Policy::Local).await;
    });
    let mut legacy = request(
        None,
        None,
        OpenMode::Open {
            name: "v8".into(),
            cwd: None,
            command: vec![common::cat()],
            cwd_from: None,
        },
    );
    legacy.version = 8;
    write_request(&mut client, &legacy).await;
    assert!(matches!(
        read_reply(&mut client).await.unwrap(),
        Opened::Attached { .. }
    ));
    read_dump(&mut client).await;
    common::write_frame(
        &mut client,
        mux_proto::frame::IN_LANE_INPUT,
        b"legacy-input\n",
    )
    .await;
    read_output_until(&mut client, b"legacy-input").await;
    manager.kill("v8");
}

async fn connect(manager: &Manager, mode: OpenMode) -> DuplexStream {
    let (mut client, server) = tokio::io::duplex(1024 * 1024);
    let manager = manager.clone();
    tokio::spawn(async move {
        let (r, w) = tokio::io::split(server);
        let _ = handle_connection(manager, r, w, &Policy::Local).await;
    });
    write_request(&mut client, &request(None, None, mode)).await;
    client
}

async fn inspect(manager: &Manager, name: &str) -> PtySnapshot {
    let mut client = connect(manager, OpenMode::Inspect { name: name.into() }).await;
    let Opened::Inspected { snapshot } = read_reply(&mut client).await.unwrap() else {
        panic!("snapshot")
    };
    snapshot
}

fn input(snapshot: &PtySnapshot, data: &[u8]) -> PtyInput {
    PtyInput {
        generation: snapshot.generation.clone(),
        revision: snapshot.revision,
        input_revision: snapshot.input_revision,
        foreground_pgid: snapshot.foreground_pgid.unwrap(),
        data: data.to_vec(),
    }
}

#[tokio::test]
async fn control_preserves_attached_client_and_rejects_replay() {
    let manager = Manager::default();
    let mut attached = connect(
        &manager,
        OpenMode::Open {
            name: "control".into(),
            cwd: None,
            command: vec![common::cat()],
            cwd_from: None,
        },
    )
    .await;
    read_reply(&mut attached).await.unwrap();
    read_dump(&mut attached).await;
    // Wait for the child to establish the terminal's foreground process group.
    let snapshot = tokio::time::timeout(common::PATIENCE, async {
        loop {
            let snapshot = inspect(&manager, "control").await;
            if snapshot.foreground_pgid.is_some_and(|pid| pid > 0) {
                break snapshot;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let mut observer = connect(
        &manager,
        OpenMode::Observe {
            name: "control".into(),
        },
    )
    .await;
    assert!(matches!(
        read_reply(&mut observer).await.unwrap(),
        Opened::Observing
    ));
    let command = input(&snapshot, b"jarvis-control-test\n");
    let mut writer = connect(
        &manager,
        OpenMode::Input {
            name: "control".into(),
            input: command.clone(),
        },
    )
    .await;
    assert!(matches!(
        read_reply(&mut writer).await.unwrap(),
        Opened::InputWritten { .. }
    ));
    read_output_until(&mut attached, b"jarvis-control-test").await;
    loop {
        let (_, payload) = common::read_frame(&mut observer)
            .await
            .expect("observer snapshot");
        let observed: PtySnapshot = mux_proto::peer::decode(&payload).unwrap();
        if observed
            .text
            .iter()
            .any(|line| line.contains("jarvis-control-test"))
        {
            break;
        }
    }
    let fresh = inspect(&manager, "control").await;
    assert_eq!((fresh.cols, fresh.rows), (80, 24));
    assert!(manager.get("control").unwrap().info().attached);
    let mut replay = connect(
        &manager,
        OpenMode::Input {
            name: "control".into(),
            input: command,
        },
    )
    .await;
    assert!(read_reply(&mut replay).await.is_err());
    assert!(manager.kill("control"));
}

#[tokio::test]
async fn human_input_invalidates_an_automation_snapshot() {
    let manager = Manager::default();
    let (session, _) = manager
        .open("draft", &[common::cat()], None, None, 91, 31)
        .unwrap();
    let snapshot = session.snapshot();
    session.write_input(b"human draft").await.unwrap();
    let mut command = input(
        &PtySnapshot {
            foreground_pgid: Some(session.child.as_raw()),
            ..snapshot
        },
        b"agent text\n",
    );
    command.revision = session.snapshot().revision;
    assert!(session.checked_input(&command).await.is_err());
    assert!(manager.kill("draft"));
}

#[tokio::test]
async fn reused_names_reject_old_generations_and_missing_reads_never_spawn() {
    let manager = Manager::default();
    let mut missing = connect(
        &manager,
        OpenMode::Inspect {
            name: "absent".into(),
        },
    )
    .await;
    assert!(read_reply(&mut missing).await.is_err());
    assert!(manager.list().is_empty());
    let (old, _) = manager
        .open("reused", &[common::cat()], None, None, 80, 24)
        .unwrap();
    let generation = old.generation.clone();
    manager.kill("reused");
    let (new, _) = manager
        .open("reused", &[common::cat()], None, None, 80, 24)
        .unwrap();
    assert_ne!(generation, new.generation);
    let mut snapshot = new.snapshot();
    snapshot.foreground_pgid = Some(new.child.as_raw());
    let mut stale = input(&snapshot, b"wrong process\n");
    stale.generation = generation;
    assert!(new.checked_input(&stale).await.is_err());
    manager.kill("reused");
}
