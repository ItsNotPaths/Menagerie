import engine/state
import engine/gameplay_vars
import engine/variables
import engine/content
import std/[tables, json]

var gs = initGameState()
echo "initGameState ok, context=", gs.context

const contentDir = "/run/media/paths/SSS-Core/python projects/Menagerie/content"

loadGameplayVars(contentDir)
echo "dodge_stamina_cost=", gvFloat("dodge_stamina_cost", 15.0)
echo "pin_duration=", gvInt("pin_duration", 2)

var vars: Table[string, JsonNode]
vars["score"] = newJInt(10)
let cond = @[%*{"var": "score", "op": "gt", "value": 5}]
echo "evalConditions(score>5)=", evalConditions(cond, vars)

loadContent(contentDir)
echo "iron-sword=", getItem("iron-sword").displayName
