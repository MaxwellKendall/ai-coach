# Spoken workout edit evals

**124/129 runs pass (96%)** · 43 cases × 3 runs · 3.4 s per run (0.4 s sorting what was said, 3.0 s making the edit)

| Pass | Day | Said / why it failed |
|---|---|---|
| ✅ 3/3 | full | Give me squats and split squat for today |
| ✅ 3/3 | full | Swap deadlifts for RDLs |
| ✅ 3/3 | full | RDLs instead of deadlifts today |
| ✅ 3/3 | full | No bench today |
| ✅ 3/3 | full | Skip the bench press |
| ✅ 3/3 | full | Just pull-ups and rows today |
| ✅ 3/3 | full | Replace bench with push-ups |
| ✅ 3/3 | full | Do dumbbell bench instead of barbell |
| ✅ 3/3 | full | Um can we do back squats instead of goblet squats |
| ✅ 3/3 | full | Swap the goblet squat for lunges |
| ✅ 3/3 | full | Drop the dead bugs and add planks |
| ✅ 3/3 | full | Add some curls at the end |
| ✅ 3/3 | full | Add farmer carries |
| ✅ 3/3 | full | Make everything 4 sets |
| ✅ 3/3 | full | Add a set to deadlifts |
| ✅ 3/3 | full | Only two sets of bench |
| ✅ 3/3 | full | Bump the deadlift to 225 |
| ✅ 3/3 | full | I want to do 8 reps on goblet squats |
| 🟡 2/3 | full | Make it a leg day |
|  | run 3 | error: Error Domain=FoundationModels.LanguageModelSession.GenerationError Code=-1 "(null)" UserInfo={NSMultipleUnderlyingErrorsKey=(
| 🟡 2/3 | full | Upper body only today |
|  | run 1 | error: Error Domain=FoundationModels.LanguageModelSession.GenerationError Code=-1 "(null)" UserInfo={NSMultipleUnderlyingErrorsKey=(
| ✅ 3/3 | upper | No pull-ups today |
| ✅ 3/3 | upper | Swap the rows for push-ups |
| ✅ 3/3 | upper | Just bench and plank |
| ✅ 3/3 | upper | Make the plank a minute |
| ✅ 3/3 | upper | Add face pulls |
| ✅ 3/3 | upper | Add dips at the end |
| ✅ 3/3 | upper | Bench 165 today |
| ✅ 3/3 | rest | Give me squats and split squat for today |
| ✅ 3/3 | rest | I want to do pull-ups and push-ups |
| ✅ 3/3 | rest | Deadlift 3 sets of 5 at 225 |
| ✅ 3/3 | rest | Give me a quick core workout |
| 🟡 1/3 | full | Regenerate today's workout |
|  | run 1 | error: Error Domain=FoundationModels.LanguageModelSession.GenerationError Code=-1 "(null)" UserInfo={NSMultipleUnderlyingErrorsKey=(
|  | run 2 | error: Error Domain=FoundationModels.LanguageModelSession.GenerationError Code=-1 "(null)" UserInfo={NSMultipleUnderlyingErrorsKey=(
| ✅ 3/3 | full | Give me a completely different workout today |
| ✅ 3/3 | full | Mix it up, I'm bored of this one |
| ✅ 3/3 | upper | Regenerate this workout |
| ✅ 3/3 | full | Give me a harder workout |
| ✅ 3/3 | full | Make it easier today |
| ✅ 3/3 | full | Dumbbells only today |
| ✅ 3/3 | full | Nothing for legs today |
| ✅ 3/3 | upper | Give me a full body workout instead |
| ✅ 3/3 | rest | Give me a workout |
| ✅ 3/3 | rest | Plan me a pull day |
| 🟡 2/3 | rest | Give me a 30 minute dumbbell workout |
|  | run 3 | 7 exercises, wanted 3–6; bench-press needs barbell, bench, rack; pull-up needs pull_up_bar; dumbbell-shoulder-press isn't in the library, so its equipment is unknown; dumbbell-bent-over-rows isn't in the library, so its equipment is unknown — `New upper body workout and 2 more changes ⇐ new_workout {"focus": "upper body", "minutes": 30} · add_exercise {"sets": 3, "exercise": "Dumbbell Bench Press", "reps": 10} · add_exercise {"reps": 10, "sets": 3, "exercise": "Dumbbell Shoulder Press"} · add_exercise {"sets": 3, "exercise": "Dumbbell Bent-Over Rows", "reps": 10}` |
