------------------------- MODULE DictationSession -------------------------
EXTENDS Naturals, FiniteSets

CONSTANT GuardInsertionCompletion
VARIABLES running, phase, current, issued, cancelled, inserting, settled,
          staleSettlement, secure, settings, activeEngine, sessionEngine,
          pendingRefresh, runID, sessionRun, plan, recordedRuns

vars == <<running, phase, current, issued, cancelled, inserting, settled,
          staleSettlement, secure, settings, activeEngine, sessionEngine,
          pendingRefresh, runID, sessionRun, plan, recordedRuns>>
Sessions == 1..2
Engines == {"local", "cloud"}
InFlight == phase \in {"listening", "transcribing", "inserting"}

Init == /\ running = TRUE /\ phase = "idle" /\ current = 0
        /\ issued = {} /\ cancelled = {} /\ inserting = {} /\ settled = {}
        /\ staleSettlement = FALSE /\ secure = FALSE
        /\ settings = "local" /\ activeEngine = "local" /\ sessionEngine = "local"
        /\ pendingRefresh = FALSE
        /\ runID = 0 /\ sessionRun = 0 /\ plan = "dictate" /\ recordedRuns = {}

Focus == /\ secure' = ~secure
         /\ UNCHANGED <<running, phase, current, issued, cancelled, inserting,
                        settled, staleSettlement, settings, activeEngine,
                        sessionEngine, pendingRefresh, runID, sessionRun, plan,
                        recordedRuns>>

ChangeSettings(engine) ==
    /\ settings' = engine
    /\ activeEngine' = IF InFlight THEN activeEngine ELSE engine
    /\ pendingRefresh' = InFlight
    /\ UNCHANGED <<running, phase, current, issued, cancelled, inserting, settled,
                   staleSettlement, secure, sessionEngine, runID, sessionRun,
                   plan, recordedRuns>>

Press(id, kind) ==
    /\ running /\ ~secure /\ ~InFlight /\ id \notin issued
    /\ phase' = "listening" /\ current' = id /\ issued' = issued \cup {id}
    /\ sessionEngine' = activeEngine /\ sessionRun' = runID /\ plan' = kind
    /\ UNCHANGED <<running, cancelled, inserting, settled, staleSettlement,
                   secure, settings, activeEngine, pendingRefresh, runID,
                   recordedRuns>>

Release == /\ phase = "listening"
           /\ phase' = "transcribing"
           /\ UNCHANGED <<running, current, issued, cancelled, inserting, settled,
                          staleSettlement, secure, settings, activeEngine,
                          sessionEngine, pendingRefresh, runID, sessionRun, plan,
                          recordedRuns>>

BeginInsertion ==
    /\ phase = "transcribing" /\ plan = "dictate"
    /\ phase' = "inserting" /\ inserting' = inserting \cup {current}
    /\ UNCHANGED <<running, current, issued, cancelled, settled, staleSettlement,
                   secure, settings, activeEngine, sessionEngine, pendingRefresh,
                   runID, sessionRun, plan, recordedRuns>>

\* Posting the paste precedes an await. Completion must recheck cancellation.
InsertionReturned(id) ==
    /\ id \in inserting
    /\ inserting' = inserting \ {id}
    /\ LET maySettle == running /\ (~GuardInsertionCompletion \/ id \notin cancelled)
       IN /\ phase' = IF maySettle THEN "settled" ELSE phase
          /\ settled' = IF maySettle THEN settled \cup {id} ELSE settled
          /\ staleSettlement' = (staleSettlement \/ (maySettle /\ id \in cancelled))
          /\ activeEngine' = IF maySettle /\ pendingRefresh THEN settings ELSE activeEngine
          /\ pendingRefresh' = IF maySettle THEN FALSE ELSE pendingRefresh
    /\ UNCHANGED <<running, current, issued, cancelled, secure, settings,
                   sessionEngine, runID, sessionRun, plan, recordedRuns>>

Compare ==
    /\ phase = "transcribing" /\ plan = "bakeoff"
    /\ phase' = "settled" /\ settled' = settled \cup {current}
    /\ recordedRuns' = IF sessionRun = runID THEN recordedRuns \cup {runID} ELSE recordedRuns
    /\ activeEngine' = IF pendingRefresh THEN settings ELSE activeEngine
    /\ pendingRefresh' = FALSE
    /\ UNCHANGED <<running, current, issued, cancelled, inserting, staleSettlement,
                   secure, settings, sessionEngine, runID, sessionRun, plan>>

Stop == /\ running
        /\ running' = FALSE /\ phase' = "idle"
        /\ cancelled' = IF InFlight THEN cancelled \cup {current} ELSE cancelled
        /\ UNCHANGED <<current, issued, inserting, settled, staleSettlement, secure,
                       settings, activeEngine, sessionEngine, pendingRefresh,
                       runID, sessionRun, plan, recordedRuns>>

Restart == /\ ~running /\ running' = TRUE
           /\ activeEngine' = settings /\ pendingRefresh' = FALSE
           /\ UNCHANGED <<phase, current, issued, cancelled, inserting, settled,
                          staleSettlement, secure, settings, sessionEngine,
                          runID, sessionRun, plan, recordedRuns>>

ResetRun == /\ runID = 0 /\ runID' = 1 /\ recordedRuns' = {}
            /\ UNCHANGED <<running, phase, current, issued, cancelled, inserting,
                           settled, staleSettlement, secure, settings, activeEngine,
                           sessionEngine, pendingRefresh, sessionRun, plan>>

Next == Focus \/ Release \/ BeginInsertion \/ Compare \/ Stop \/ Restart \/ ResetRun
        \/ (\E engine \in Engines : ChangeSettings(engine))
        \/ (\E id \in Sessions : InsertionReturned(id))
        \/ (\E id \in Sessions, kind \in {"dictate", "bakeoff"} : Press(id, kind))

Spec == Init /\ [][Next]_vars
TypeOK == /\ running \in BOOLEAN /\ secure \in BOOLEAN
          /\ phase \in {"idle", "listening", "transcribing", "inserting", "settled"}
          /\ current \in 0..2 /\ issued \subseteq Sessions
          /\ cancelled \subseteq issued /\ inserting \subseteq issued /\ settled \subseteq issued
          /\ staleSettlement \in BOOLEAN /\ pendingRefresh \in BOOLEAN
          /\ settings \in Engines /\ activeEngine \in Engines /\ sessionEngine \in Engines
          /\ runID \in 0..1 /\ sessionRun \in 0..1
          /\ plan \in {"dictate", "bakeoff"} /\ recordedRuns \subseteq 0..1
NoStaleSettlement == ~staleSettlement
EngineSnapshot == InFlight => sessionEngine = activeEngine
NoStoppedSession == ~running => ~InFlight
RunIsolation == recordedRuns \subseteq {runID}
=============================================================================
