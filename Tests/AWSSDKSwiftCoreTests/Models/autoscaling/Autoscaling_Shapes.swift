// THIS FILE IS COPIED FROM THE OUTPUT of https://github.com/noppoMan/aws-sdk-swift/blob/master/Sources/CodeGenerator/main.swift

import Foundation
import AWSSDKSwiftCore

struct Autoscaling {
    public struct EnabledMetric: AWSShape {
        public static var _members: [AWSShapeMember] = [
            AWSShapeMember(label: "Granularity", required: false, type: .string),
            AWSShapeMember(label: "Metric", required: false, type: .string)
        ]
        /// The granularity of the metric. The only valid value is 1Minute.
        public let granularity: String?
        /// One of the following metrics:    GroupMinSize     GroupMaxSize     GroupDesiredCapacity     GroupInServiceInstances     GroupPendingInstances     GroupStandbyInstances     GroupTerminatingInstances     GroupTotalInstances
        public let metric: String?

        public init(granularity: String? = nil, metric: String? = nil) {
            self.granularity = granularity
            self.metric = metric
        }

        private enum CodingKeys: String, CodingKey {
            case granularity = "Granularity"
            case metric = "Metric"
        }
    }

    public struct TagDescription: AWSShape {
        public static var _members: [AWSShapeMember] = [
            AWSShapeMember(label: "Key", required: false, type: .string),
            AWSShapeMember(label: "PropagateAtLaunch", required: false, type: .boolean),
            AWSShapeMember(label: "Value", required: false, type: .string),
            AWSShapeMember(label: "ResourceType", required: false, type: .string),
            AWSShapeMember(label: "ResourceId", required: false, type: .string)
        ]
        /// The tag key.
        public let key: String?
        /// Determines whether the tag is added to new instances as they are launched in the group.
        public let propagateAtLaunch: Bool?
        /// The tag value.
        public let value: String?
        /// The type of resource. The only supported value is auto-scaling-group.
        public let resourceType: String?
        /// The name of the group.
        public let resourceId: String?

        public init(key: String? = nil, propagateAtLaunch: Bool? = nil, value: String? = nil, resourceType: String? = nil, resourceId: String? = nil) {
            self.key = key
            self.propagateAtLaunch = propagateAtLaunch
            self.value = value
            self.resourceType = resourceType
            self.resourceId = resourceId
        }

        private enum CodingKeys: String, CodingKey {
            case key = "Key"
            case propagateAtLaunch = "PropagateAtLaunch"
            case value = "Value"
            case resourceType = "ResourceType"
            case resourceId = "ResourceId"
        }
    }

    public struct SuspendedProcess: AWSShape {
        public static var _members: [AWSShapeMember] = [
            AWSShapeMember(label: "ProcessName", required: false, type: .string),
            AWSShapeMember(label: "SuspensionReason", required: false, type: .string)
        ]
        /// The name of the suspended process.
        public let processName: String?
        /// The reason that the process was suspended.
        public let suspensionReason: String?

        public init(processName: String? = nil, suspensionReason: String? = nil) {
            self.processName = processName
            self.suspensionReason = suspensionReason
        }

        private enum CodingKeys: String, CodingKey {
            case processName = "ProcessName"
            case suspensionReason = "SuspensionReason"
        }
    }

    public struct LaunchTemplateSpecification: AWSShape {
        public static var _members: [AWSShapeMember] = [
            AWSShapeMember(label: "LaunchTemplateName", required: false, type: .string),
            AWSShapeMember(label: "LaunchTemplateId", required: false, type: .string),
            AWSShapeMember(label: "Version", required: false, type: .string)
        ]
        /// The name of the launch template. You must specify either a template name or a template ID.
        public let launchTemplateName: String?
        /// The ID of the launch template. You must specify either a template ID or a template name.
        public let launchTemplateId: String?
        /// The version number. By default, the default version of the launch template is used.
        public let version: String?

        public init(launchTemplateName: String? = nil, launchTemplateId: String? = nil, version: String? = nil) {
            self.launchTemplateName = launchTemplateName
            self.launchTemplateId = launchTemplateId
            self.version = version
        }

        private enum CodingKeys: String, CodingKey {
            case launchTemplateName = "LaunchTemplateName"
            case launchTemplateId = "LaunchTemplateId"
            case version = "Version"
        }
    }

    public struct Instance: AWSShape {
        public static var _members: [AWSShapeMember] = [
            AWSShapeMember(label: "LaunchConfigurationName", required: false, type: .string),
            AWSShapeMember(label: "LifecycleState", required: true, type: .enum),
            AWSShapeMember(label: "InstanceId", required: true, type: .string),
            AWSShapeMember(label: "ProtectedFromScaleIn", required: true, type: .boolean),
            AWSShapeMember(label: "HealthStatus", required: true, type: .string),
            AWSShapeMember(label: "LaunchTemplate", required: false, type: .structure),
            AWSShapeMember(label: "AvailabilityZone", required: true, type: .string)
        ]
        /// The launch configuration associated with the instance.
        public let launchConfigurationName: String?
        /// A description of the current lifecycle state. Note that the Quarantined state is not used.
        public let lifecycleState: LifecycleState
        /// The ID of the instance.
        public let instanceId: String
        /// Indicates whether the instance is protected from termination by Auto Scaling when scaling in.
        public let protectedFromScaleIn: Bool
        /// The last reported health status of the instance. "Healthy" means that the instance is healthy and should remain in service. "Unhealthy" means that the instance is unhealthy and Auto Scaling should terminate and replace it.
        public let healthStatus: String
        /// The launch template for the instance.
        public let launchTemplate: LaunchTemplateSpecification?
        /// The Availability Zone in which the instance is running.
        public let availabilityZone: String

        public init(launchConfigurationName: String? = nil, lifecycleState: LifecycleState, instanceId: String, protectedFromScaleIn: Bool, healthStatus: String, launchTemplate: LaunchTemplateSpecification? = nil, availabilityZone: String) {
            self.launchConfigurationName = launchConfigurationName
            self.lifecycleState = lifecycleState
            self.instanceId = instanceId
            self.protectedFromScaleIn = protectedFromScaleIn
            self.healthStatus = healthStatus
            self.launchTemplate = launchTemplate
            self.availabilityZone = availabilityZone
        }

        private enum CodingKeys: String, CodingKey {
            case launchConfigurationName = "LaunchConfigurationName"
            case lifecycleState = "LifecycleState"
            case instanceId = "InstanceId"
            case protectedFromScaleIn = "ProtectedFromScaleIn"
            case healthStatus = "HealthStatus"
            case launchTemplate = "LaunchTemplate"
            case availabilityZone = "AvailabilityZone"
        }
    }

    public enum LifecycleState: String, CustomStringConvertible, Codable {
        case pending = "Pending"
        case pendingWait = "Pending:Wait"
        case pendingProceed = "Pending:Proceed"
        case quarantined = "Quarantined"
        case inservice = "InService"
        case terminating = "Terminating"
        case terminatingWait = "Terminating:Wait"
        case terminatingProceed = "Terminating:Proceed"
        case terminated = "Terminated"
        case detaching = "Detaching"
        case detached = "Detached"
        case enteringstandby = "EnteringStandby"
        case standby = "Standby"
        public var description: String { return self.rawValue }
    }

    public struct AutoScalingGroupsType: AWSShape {
        public static var _members: [AWSShapeMember] = [
            AWSShapeMember(label: "NextToken", required: false, type: .string),
            AWSShapeMember(label: "AutoScalingGroups", required: true, type: .list)
        ]
        /// The token to use when requesting the next set of items. If there are no additional items to return, the string is empty.
        public let nextToken: String?
        /// The groups.
        public let autoScalingGroups: [AutoScalingGroup]

        public init(nextToken: String? = nil, autoScalingGroups: [AutoScalingGroup]) {
            self.nextToken = nextToken
            self.autoScalingGroups = autoScalingGroups
        }

        private enum CodingKeys: String, CodingKey {
            case nextToken = "NextToken"
            case autoScalingGroups = "AutoScalingGroups"
        }
    }

    public struct AutoScalingGroup: AWSShape {
        public static var _members: [AWSShapeMember] = [
            AWSShapeMember(label: "AvailabilityZones", required: true, type: .list),
            AWSShapeMember(label: "EnabledMetrics", required: false, type: .list),
            AWSShapeMember(label: "LaunchConfigurationName", required: false, type: .string),
            AWSShapeMember(label: "NewInstancesProtectedFromScaleIn", required: false, type: .boolean),
            AWSShapeMember(label: "VPCZoneIdentifier", required: false, type: .string),
            AWSShapeMember(label: "Tags", required: false, type: .list),
            AWSShapeMember(label: "MaxSize", required: true, type: .integer),
            AWSShapeMember(label: "SuspendedProcesses", required: false, type: .list),
            AWSShapeMember(label: "TargetGroupARNs", required: false, type: .list),
            AWSShapeMember(label: "CreatedTime", required: true, type: .timestamp),
            AWSShapeMember(label: "Status", required: false, type: .string),
            AWSShapeMember(label: "MinSize", required: true, type: .integer),
            AWSShapeMember(label: "DesiredCapacity", required: true, type: .integer),
            AWSShapeMember(label: "AutoScalingGroupARN", required: false, type: .string),
            AWSShapeMember(label: "PlacementGroup", required: false, type: .string),
            AWSShapeMember(label: "DefaultCooldown", required: true, type: .integer),
            AWSShapeMember(label: "Instances", required: false, type: .list),
            AWSShapeMember(label: "TerminationPolicies", required: false, type: .list),
            AWSShapeMember(label: "LaunchTemplate", required: false, type: .structure),
            AWSShapeMember(label: "HealthCheckGracePeriod", required: false, type: .integer),
            AWSShapeMember(label: "LoadBalancerNames", required: false, type: .list),
            AWSShapeMember(label: "HealthCheckType", required: true, type: .string),
            AWSShapeMember(label: "AutoScalingGroupName", required: true, type: .string)
        ]
        /// One or more Availability Zones for the group.
        public let availabilityZones: [String]
        /// The metrics enabled for the group.
        public let enabledMetrics: [EnabledMetric]?
        /// The name of the associated launch configuration.
        public let launchConfigurationName: String?
        /// Indicates whether newly launched instances are protected from termination by Auto Scaling when scaling in.
        public let newInstancesProtectedFromScaleIn: Bool?
        /// One or more subnet IDs, if applicable, separated by commas. If you specify VPCZoneIdentifier and AvailabilityZones, ensure that the Availability Zones of the subnets match the values for AvailabilityZones.
        public let vPCZoneIdentifier: String?
        /// The tags for the group.
        public let tags: [TagDescription]?
        /// The maximum size of the group.
        public let maxSize: Int32
        /// The suspended processes associated with the group.
        public let suspendedProcesses: [SuspendedProcess]?
        /// The Amazon Resource Names (ARN) of the target groups for your load balancer.
        public let targetGroupARNs: [String]?
        /// The date and time the group was created.
        public let createdTime: TimeStamp
        /// The current state of the group when DeleteAutoScalingGroup is in progress.
        public let status: String?
        /// The minimum size of the group.
        public let minSize: Int32
        /// The desired size of the group.
        public let desiredCapacity: Int32
        /// The Amazon Resource Name (ARN) of the Auto Scaling group.
        public let autoScalingGroupARN: String?
        /// The name of the placement group into which you'll launch your instances, if any. For more information, see Placement Groups in the Amazon Elastic Compute Cloud User Guide.
        public let placementGroup: String?
        /// The amount of time, in seconds, after a scaling activity completes before another scaling activity can start.
        public let defaultCooldown: Int32
        /// The EC2 instances associated with the group.
        public let instances: [Instance]?
        /// The termination policies for the group.
        public let terminationPolicies: [String]?
        /// The launch template for the group.
        public let launchTemplate: LaunchTemplateSpecification?
        /// The amount of time, in seconds, that Auto Scaling waits before checking the health status of an EC2 instance that has come into service.
        public let healthCheckGracePeriod: Int32?
        /// One or more load balancers associated with the group.
        public let loadBalancerNames: [String]?
        /// The service to use for the health checks. The valid values are EC2 and ELB.
        public let healthCheckType: String
        /// The name of the Auto Scaling group.
        public let autoScalingGroupName: String

        public init(availabilityZones: [String], enabledMetrics: [EnabledMetric]? = nil, launchConfigurationName: String? = nil, newInstancesProtectedFromScaleIn: Bool? = nil, vPCZoneIdentifier: String? = nil, tags: [TagDescription]? = nil, maxSize: Int32, suspendedProcesses: [SuspendedProcess]? = nil, targetGroupARNs: [String]? = nil, createdTime: TimeStamp, status: String? = nil, minSize: Int32, desiredCapacity: Int32, autoScalingGroupARN: String? = nil, placementGroup: String? = nil, defaultCooldown: Int32, instances: [Instance]? = nil, terminationPolicies: [String]? = nil, launchTemplate: LaunchTemplateSpecification? = nil, healthCheckGracePeriod: Int32? = nil, loadBalancerNames: [String]? = nil, healthCheckType: String, autoScalingGroupName: String) {
            self.availabilityZones = availabilityZones
            self.enabledMetrics = enabledMetrics
            self.launchConfigurationName = launchConfigurationName
            self.newInstancesProtectedFromScaleIn = newInstancesProtectedFromScaleIn
            self.vPCZoneIdentifier = vPCZoneIdentifier
            self.tags = tags
            self.maxSize = maxSize
            self.suspendedProcesses = suspendedProcesses
            self.targetGroupARNs = targetGroupARNs
            self.createdTime = createdTime
            self.status = status
            self.minSize = minSize
            self.desiredCapacity = desiredCapacity
            self.autoScalingGroupARN = autoScalingGroupARN
            self.placementGroup = placementGroup
            self.defaultCooldown = defaultCooldown
            self.instances = instances
            self.terminationPolicies = terminationPolicies
            self.launchTemplate = launchTemplate
            self.healthCheckGracePeriod = healthCheckGracePeriod
            self.loadBalancerNames = loadBalancerNames
            self.healthCheckType = healthCheckType
            self.autoScalingGroupName = autoScalingGroupName
        }

        private enum CodingKeys: String, CodingKey {
            case availabilityZones = "AvailabilityZones"
            case enabledMetrics = "EnabledMetrics"
            case launchConfigurationName = "LaunchConfigurationName"
            case newInstancesProtectedFromScaleIn = "NewInstancesProtectedFromScaleIn"
            case vPCZoneIdentifier = "VPCZoneIdentifier"
            case tags = "Tags"
            case maxSize = "MaxSize"
            case suspendedProcesses = "SuspendedProcesses"
            case targetGroupARNs = "TargetGroupARNs"
            case createdTime = "CreatedTime"
            case status = "Status"
            case minSize = "MinSize"
            case desiredCapacity = "DesiredCapacity"
            case autoScalingGroupARN = "AutoScalingGroupARN"
            case placementGroup = "PlacementGroup"
            case defaultCooldown = "DefaultCooldown"
            case instances = "Instances"
            case terminationPolicies = "TerminationPolicies"
            case launchTemplate = "LaunchTemplate"
            case healthCheckGracePeriod = "HealthCheckGracePeriod"
            case loadBalancerNames = "LoadBalancerNames"
            case healthCheckType = "HealthCheckType"
            case autoScalingGroupName = "AutoScalingGroupName"
        }
    }
}
