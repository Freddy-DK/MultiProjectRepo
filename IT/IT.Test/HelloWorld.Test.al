codeunit 90051 "HelloWorld Test IT"
{
    Subtype = Test;

    [Test]
    procedure TestHelloWorldMessage()
    var
        CustList: TestPage "Customer List";
    begin
        CustList.OpenView();
        CustList.Close();
    end;
}

