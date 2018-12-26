#!/bin/bash
START_TIME=$(date +"%Y-%m-%dT%T")

ELB_NAME=""
RECIPIENTS=""
RELEASE_RESULT="COMPLETED"
BRANCH="master"
KEY_PATH=""
SCRIPT_PATH="{update_code_sricpt}.sh"
USE_DOCKER_FOR_PRIMARIES="0"
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
NOT_UPDATE_CELERY="0"
NOT_BUILD_PACKER="0"

while getopts "e:r:b:i:s:d:c:p:" flag; do
        case $flag in
                e) ELB_NAME=$OPTARG ;;
                r) RECIPIENTS=$OPTARG ;;
                b) BRANCH=$OPTARG ;;
                i) KEY_PATH=$OPTARG ;;
                s) SCRIPT_PATH=$OPTARG ;;
                d) USE_DOCKER_FOR_PRIMARIES=$OPTARG ;;
                c) NOT_UPDATE_CELERY=$OPTARG ;;
                p) NOT_BUILD_PACKER=$OPTARG ;;
                *) error "Unexpected option: please check the flag $flag" ;;
        esac
done

mkdir -p /tmp/ci/releases/$START_TIME
TEMP_DIR=$(mktemp -d -t -p "/tmp/ci/releases/$START_TIME")
LOG_PATH=$TEMP_DIR/release-$PRIVATE_IP-$START_TIME.log
EMAIL_BODY_PATH=$TEMP_DIR/email_body.txt
printf "\n\nWriting logs to: $LOG_PATH\n"

# Closing stdout and stderr
exec 3>&1 4>&2

exec 1>$LOG_PATH
exec 2>&1

if [ "$NOT_UPDATE_CELERY" == "1" ]
then
    printf "\n\nProceed without updating celery\n"
else
    printf "\n\nUpdating Celeries\n"
    celeries=$({get_docker_machine_names_script}.sh "celery")
    for celery in $celeries
    do
        printf "\n\nUpdating $celery At $(date +'%Y-%m-%d %T')\n"
        docker-machine ssh $celery "bash -s" -- < {update_celery_script}.sh -b $BRANCH
    done
fi

printf "\n\nUpdating Primaries\n"
if [ "$USE_DOCKER_FOR_PRIMARIES" == "1" ]
then
    for production in $({get_docker_machine_names_script}.sh "production")
    do
        INSTANCE_ID=$(echo 'wget -q -O - http://169.254.169.254/latest/meta-data/instance-id' | docker-machine ssh $production | grep -E '^i-[[:alnum:]]+$')
        ELB_DESCRIPTION=$(aws elb describe-load-balancers --load-balancer-names $ELB_NAME)
        if [[ $ELB_DESCRIPTION == *"$INSTANCE_ID"* ]]; then
            printf "\n\nDeregistering $production ($INSTANCE_ID) At $(date +'%Y-%m-%d %T')\n"
            aws elb deregister-instances-from-load-balancer --load-balancer-name $ELB_NAME --instances $INSTANCE_ID

            printf "\n\nUpdating $production ($INSTANCE_ID) At $(date +'%Y-%m-%d %T')\n"
            docker-machine ssh $production "bash -s" -- < update_production.sh -b $BRANCH

            printf "\n\nRegistering $production ($INSTANCE_ID) At $(date +'%Y-%m-%d %T')\n"
            aws elb register-instances-with-load-balancer --load-balancer-name $ELB_NAME --instances $INSTANCE_ID

            printf "\n\nWaiting $production ($INSTANCE_ID) At $(date +'%Y-%m-%d %T')\n"
            for i in {1..18}
            do
                INSTANCE_HEALTH_RESULT=$(aws elb describe-instance-health --load-balancer-name $ELB_NAME --instances $INSTANCE_ID)
                INSTANCE_HEALTH=$(python utils/parse_json_and_get_value_using_key.py "$INSTANCE_HEALTH_RESULT" "InstanceStates.0.State")
                if [ $INSTANCE_HEALTH = "InService" ]
                then
                    printf "\n\nFinished Waiting $production ($INSTANCE_ID) At $(date +'%Y-%m-%d %T')\n"
                    break
                fi
                sleep 10
            done

            if [ i = 18 ] && [ $INSTANCE_HEALTH != "InService" ]
            then
                printf "\n\nFound $production ($INSTANCE_ID) Failed At $(date +'%Y-%m-%d %T')\n"
                RELEASE_RESULT="FAILED"
                break
            fi
        else
            printf "\n\nFound $production ($INSTANCE_ID) is not an EC2 instance registered at $ELB_NAME; skipping updating $production ($INSTANCE_ID)\n"
        fi
    done
else
    source ~/{python_production_path}/env/bin/activate
    python release_to_productions.py -e $ELB_NAME -b $BRANCH -i $KEY_PATH -s $SCRIPT_PATH
    deactivate
fi

if [ "$NOT_BUILD_PACKER" == "1" ]
then
    printf "\n\nFinished to release without running a packer\n"
else
    printf "\n\nUpdating Launch Configurations & Auto Scaling\n"
    source ~/{python_production_path}/env/bin/activate
    cd ci_autoscaling
    ./release_to_asg.sh aws_asg_envvars.config
    deactivate
    cd ..
fi

exec 1>&3 2>&4

EMAIL_SUBJECT="[($PRIVATE_IP) CI Release Result] $RELEASE_RESULT ($START_TIME)"
cat $LOG_PATH | grep -E '.+ At [[:digit:]]{4}-[[:digit:]]{2}-[[:digit:]]{2}.+|{python_production_path}.continuous_integration.release_to_productions' >> $EMAIL_BODY_PATH
sed -i -e 's/^/\n* /' $EMAIL_BODY_PATH
mutt -s "$EMAIL_SUBJECT" -a $LOG_PATH -- $RECIPIENTS < $EMAIL_BODY_PATH