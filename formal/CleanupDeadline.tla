------------------------- MODULE CleanupDeadline -------------------------
EXTENDS Naturals, FiniteSets

CONSTANT HandleCancellation
VARIABLES installed, started, tracked, stopped, arrived, winner, resumes,
          cancelledFirst

vars == <<installed, started, tracked, stopped, arrived, winner, resumes,
          cancelledFirst>>
Tasks == {"worker", "timer"}
Events == Tasks \cup {"cancel"}

Init == /\ installed = FALSE
        /\ started = {}
        /\ tracked = {}
        /\ stopped = {}
        /\ arrived = {}
        /\ winner = "none"
        /\ resumes = 0
        /\ cancelledFirst = FALSE

Install == /\ ~installed
           /\ installed' = TRUE
           /\ resumes' = IF winner = "none" THEN 0 ELSE 1
           /\ UNCHANGED <<started, tracked, stopped, arrived, winner,
                          cancelledFirst>>

Start(task) == /\ installed /\ winner = "none" /\ task \notin started
               /\ started' = started \cup {task}
               /\ UNCHANGED <<installed, tracked, stopped, arrived, winner,
                              resumes, cancelledFirst>>

\* Registration can lose the race to completion: track() must cancel late tasks.
Track(task) == /\ task \in started \ tracked
               /\ tracked' = tracked \cup {task}
               /\ stopped' = IF winner = "none" THEN stopped
                              ELSE stopped \cup {task}
               /\ UNCHANGED <<installed, started, arrived, winner, resumes,
                              cancelledFirst>>

\* A non-cooperative worker may return even after cancellation.
Arrive(event) ==
    /\ event \notin arrived
    /\ (event = "cancel" \/ event \in started)
    /\ arrived' = arrived \cup {event}
    /\ cancelledFirst' = (cancelledFirst \/ (event = "cancel" /\ winner = "none"))
    /\ LET resolves == winner = "none" /\ (event # "cancel" \/ HandleCancellation)
       IN /\ winner' = IF resolves THEN event ELSE winner
          /\ resumes' = IF resolves /\ installed THEN resumes + 1 ELSE resumes
          /\ stopped' = IF resolves THEN stopped \cup tracked ELSE stopped
    /\ UNCHANGED <<installed, started, tracked>>

Next == Install
        \/ (\E task \in Tasks : Start(task) \/ Track(task))
        \/ (\E event \in Events : Arrive(event))

Spec == Init /\ [][Next]_vars
        /\ WF_vars(Install)
        /\ WF_vars(Start("timer"))
        /\ WF_vars(Arrive("timer"))

TypeOK == /\ installed \in BOOLEAN
          /\ started \subseteq Tasks /\ tracked \subseteq started
          /\ stopped \subseteq tracked /\ arrived \subseteq Events
          /\ winner \in Events \cup {"none"}
          /\ resumes \in 0..1 /\ cancelledFirst \in BOOLEAN
SingleDelivery == resumes <= 1
CancellationWins == cancelledFirst => winner = "cancel"
ResourcesReleased == winner # "none" => tracked \subseteq stopped
ResultDelivered == installed /\ winner # "none" => resumes = 1
EventuallyDelivered == <> (resumes = 1)
=============================================================================
