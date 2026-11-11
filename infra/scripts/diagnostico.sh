#!/usr/bin/env bash
# Revisa por qué la API no alcanza la base de datos. No muestra secretos.
# Uso: infra/scripts/diagnostico.sh
set -uo pipefail

INFRA=$(cd "$(dirname "$0")/.." && pwd)
source "$INFRA/scripts/lib/tarea_base.sh"

db=$(salida db_direccion | cut -d. -f1)
fn=$(salida api_funcion)

echo "== Base de datos =="
aws rds describe-db-instances --db-instance-identifier "$db" --output table --query \
  'DBInstances[0].{Estado:DBInstanceStatus,VPC:DBSubnetGroup.VpcId,IAM:IAMDatabaseAuthenticationEnabled,Grupos:join(`", "`,VpcSecurityGroups[].VpcSecurityGroupId),Subredes:join(`", "`,DBSubnetGroup.Subnets[].SubnetIdentifier)}'

echo "== Función de la API =="
aws lambda get-function-configuration --function-name "$fn" --output table --query \
  '{Estado:State,Actualizacion:LastUpdateStatus,Razon:StateReason,VPC:VpcConfig.VpcId,Grupos:join(`", "`,VpcConfig.SecurityGroupIds),Subredes:join(`", "`,VpcConfig.SubnetIds),Host:Environment.Variables.DB_HOST}'

echo "== Reglas de los grupos de seguridad =="
for g in api db; do
  id=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=paritario-piloto-$g" \
    --query 'SecurityGroups[0].GroupId' --output text)
  echo "-- paritario-piloto-$g ($id)"
  aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$id" --output table --query \
    'SecurityGroupRules[].{Salida:IsEgress,Puerto:FromPort,Hacia_o_desde:join(`""`,[ReferencedGroupInfo.GroupId||`""`,CidrIpv4||`""`,PrefixListId||`""`])}'
done

echo "== Errores de la API (última hora) =="
MSYS_NO_PATHCONV=1 aws logs tail "/aws/lambda/$fn" --since 1h --format short \
  --filter-pattern '{ $.level >= 50 }' 2>&1 | tail -n 5 | cut -c1-300
