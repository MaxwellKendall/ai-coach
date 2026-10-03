import { CloudFormationClient, DescribeStacksCommand } from "@aws-sdk/client-cloudformation";

/** Reads the CfnOutputs of AICoach-{stage} using the current AWS profile. */
export async function stackOutputs(stage: string, region = "us-east-1") {
  const cfn = new CloudFormationClient({ region });
  const { Stacks } = await cfn.send(new DescribeStacksCommand({ StackName: `AICoach-${stage}` }));
  return Object.fromEntries((Stacks?.[0]?.Outputs ?? []).map((o) => [o.OutputKey!, o.OutputValue!]));
}
