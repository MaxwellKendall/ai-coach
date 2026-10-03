# Spoken workout edit evals

Strategy: `agent`

**116/129 runs pass (89%)** · 43 cases × 3 runs · 8.2 s per run

| Pass | Day | Said / why it failed |
|---|---|---|
| ❌ 0/3 | full | Give me squats and split squat for today |
|  | run 1 | added dumbbell-romanian-deadlift, not asked for; added farmer-carry, not asked for; added plank, not asked for; dropped deadlift, not asked for; dropped bench-press, not asked for; dropped dead-bug, not asked for — `New leg workout, Split Squat added ⇐ new_workout {"equipment": "everything", "focus": "lower body"} · swap_exercise {"exercise": "Dead Bug", "replacement": "Split Squat", "pattern": "squat"} · add_exercise {"pattern": "squat", "sets": 3, "exercise": "Split Squat", "reps": 10}` |
|  | run 2 | added dumbbell-romanian-deadlift, not asked for; added farmer-carry, not asked for; added plank, not asked for; dropped deadlift, not asked for; dropped bench-press, not asked for; dropped dead-bug, not asked for — `New leg workout, Split Squat added ⇐ new_workout {"focus": "lower body", "equipment": "everything"} · swap_exercise {"exercise": "Dead Bug", "pattern": "squat", "replacement": "Split Squat"} · add_exercise {"exercise": "Split Squat", "pattern": "squat"}` |
|  | run 3 | added dumbbell-romanian-deadlift, not asked for; added farmer-carry, not asked for; added plank, not asked for; dropped deadlift, not asked for; dropped bench-press, not asked for; dropped dead-bug, not asked for — `New leg workout, Split Squat added ⇐ new_workout {"focus": "lower body", "equipment": "everything"} · add_exercise {"pattern": "squat", "exercise": "split squat"} · add_exercise {"pattern": "squat", "exercise": "squat"}` |
| ✅ 3/3 | full | Swap deadlifts for RDLs |
| ✅ 3/3 | full | RDLs instead of deadlifts today |
| ✅ 3/3 | full | No bench today |
| ✅ 3/3 | full | Skip the bench press |
| ✅ 3/3 | full | Just pull-ups and rows today |
| ✅ 3/3 | full | Replace bench with push-ups |
| 🟡 2/3 | full | Do dumbbell bench instead of barbell |
|  | run 2 | error: Error Domain=FoundationModels.LanguageModelSession.GenerationError Code=-1 "(null)" UserInfo={NSMultipleUnderlyingErrorsKey=(
| ✅ 3/3 | full | Um can we do back squats instead of goblet squats |
| ✅ 3/3 | full | Swap the goblet squat for lunges |
| 🟡 2/3 | full | Drop the dead bugs and add planks |
|  | run 1 | missing plank — `Dead Bug out ⇐ change_exercise {"more_sets": 1, "sets": 4, "exercise": "every exercise"} · remove_exercises {"exercises": ["Dead Bug"]}` |
| ✅ 3/3 | full | Add some curls at the end |
| ✅ 3/3 | full | Add farmer carries |
| ✅ 3/3 | full | Make everything 4 sets |
| 🟡 1/3 | full | Add a set to deadlifts |
|  | run 2 | nothing changed — ` ⇐ add_exercise {"exercise": "Deadlift", "sets": 4}` |
|  | run 3 | nothing changed — ` ⇐ add_exercise {"sets": 4, "exercise": "Deadlift"}` |
| ✅ 3/3 | full | Only two sets of bench |
| ✅ 3/3 | full | Bump the deadlift to 225 |
| ✅ 3/3 | full | I want to do 8 reps on goblet squats |
| ✅ 3/3 | full | Make it a leg day |
| ✅ 3/3 | full | Upper body only today |
| ✅ 3/3 | upper | No pull-ups today |
| ✅ 3/3 | upper | Swap the rows for push-ups |
| 🟡 1/3 | upper | Just bench and plank |
|  | run 2 | missing bench-press; missing plank; added dumbbell-row, not asked for; added pull-up, not asked for — `Bench Press out, Plank (Forearm) out ⇐ remove_exercises {"exercises": ["Bench Press", "Plank (Forearm)"]}` |
|  | run 3 | missing bench-press; missing plank; added dumbbell-row, not asked for; added pull-up, not asked for — `Bench Press out, Plank (Forearm) out ⇐ remove_exercises {"exercises": ["Bench Press", "Plank (Forearm)"]}` |
| ✅ 3/3 | upper | Make the plank a minute |
| ✅ 3/3 | upper | Add face pulls |
| ✅ 3/3 | upper | Add dips at the end |
| ✅ 3/3 | upper | Bench 165 today |
| 🟡 2/3 | rest | Give me squats and split squat for today |
|  | run 2 | added dead-bug, not asked for; added dumbbell-romanian-deadlift, not asked for; added farmer-carry, not asked for — `New leg workout, Split Squat added ⇐ new_workout {"equipment": "everything", "focus": "lower body"} · add_exercise {"exercise": "Split Squat"}` |
| ✅ 3/3 | rest | I want to do pull-ups and push-ups |
| ✅ 3/3 | rest | Deadlift 3 sets of 5 at 225 |
| ✅ 3/3 | rest | Give me a quick core workout |
| ✅ 3/3 | full | Regenerate today's workout |
| ✅ 3/3 | full | Give me a completely different workout today |
| ✅ 3/3 | full | Mix it up, I'm bored of this one |
| ✅ 3/3 | upper | Regenerate this workout |
| ✅ 3/3 | full | Give me a harder workout |
| ✅ 3/3 | full | Make it easier today |
| ✅ 3/3 | full | Dumbbells only today |
| ❌ 0/3 | full | Nothing for legs today |
|  | run 1 | has back-squat (squat); has goblet-squat (squat) — `New leg workout ⇐ new_workout {"equipment": "everything", "focus": "lower body"}` |
|  | run 2 | has back-squat (squat); has goblet-squat (squat) — `New leg workout ⇐ new_workout {"focus": "lower body", "equipment": "everything"}` |
|  | run 3 | has back-squat (squat); has goblet-squat (squat) — `New leg workout ⇐ new_workout {"equipment": "everything", "focus": "lower body"}` |
| ✅ 3/3 | upper | Give me a full body workout instead |
| ✅ 3/3 | rest | Give me a workout |
| ✅ 3/3 | rest | Plan me a pull day |
| ✅ 3/3 | rest | Give me a 30 minute dumbbell workout |
