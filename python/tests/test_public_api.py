def test_top_level_exports():
    import hydra_client
    for name in ("HydraClient", "TaskSpec", "ResourceRequirements",
                 "Task", "Device", "WorkerSnapshot", "Worker",
                 "HydraError", "TaskFailedError"):
        assert hasattr(hydra_client, name), name
    from hydra_client import sim
    assert callable(sim.score_for_task)
